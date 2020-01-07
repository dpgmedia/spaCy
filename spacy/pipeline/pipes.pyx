# cython: infer_types=True
# cython: profile=True
import numpy
import srsly
import random
from thinc.layers import chain, Affine, Maxout, Softmax, LayerNorm, list2array
from thinc.initializers import zero_init
from thinc.loss import cosine_distance
from thinc.util import to_categorical
from thinc.util import get_array_module

from ..tokens.doc cimport Doc
from ..syntax.nn_parser cimport Parser
from ..syntax.ner cimport BiluoPushDown
from ..syntax.arc_eager cimport ArcEager
from ..morphology cimport Morphology
from ..vocab cimport Vocab

from .functions import merge_subtokens
from ..language import Language, component
from ..syntax import nonproj
from ..gold import Example
from ..attrs import POS, ID
from ..util import link_vectors_to_models, create_default_optimizer
from ..parts_of_speech import X
from ..kb import KnowledgeBase
from ..ml.component_models import Tok2Vec, build_tagger_model
from ..ml.component_models import build_text_classifier
from ..ml.component_models import build_simple_cnn_text_classifier
from ..ml.component_models import build_bow_text_classifier, build_nel_encoder
from ..ml.component_models import masked_language_model
from ..errors import Errors, TempErrors, user_warning, Warnings
from .. import util


def _load_cfg(path):
    if path.exists():
        return srsly.read_json(path)
    else:
        return {}


class Pipe(object):
    """This class is not instantiated directly. Components inherit from it, and
    it defines the interface that components should follow to function as
    components in a spaCy analysis pipeline.
    """

    name = None

    @classmethod
    def Model(cls, *shape, **kwargs):
        """Initialize a model for the pipe."""
        raise NotImplementedError

    @classmethod
    def from_nlp(cls, nlp, **cfg):
        return cls(nlp.vocab, **cfg)

    def _get_doc(self, example):
        """ Use this method if the `example` can be both a Doc or an Example """
        if isinstance(example, Doc):
            return example
        return example.doc

    def __init__(self, vocab, model=True, **cfg):
        """Create a new pipe instance."""
        raise NotImplementedError

    def __call__(self, example):
        """Apply the pipe to one document. The document is
        modified in-place, and returned.

        Both __call__ and pipe should delegate to the `predict()`
        and `set_annotations()` methods.
        """
        self.require_model()
        doc = self._get_doc(example)
        predictions = self.predict([doc])
        if isinstance(predictions, tuple) and len(predictions) == 2:
            scores, tensors = predictions
            self.set_annotations([doc], scores, tensors=tensors)
        else:
            self.set_annotations([doc], predictions)
        if isinstance(example, Example):
            example.doc = doc
            return example
        return doc

    def require_model(self):
        """Raise an error if the component's model is not initialized."""
        if getattr(self, "model", None) in (None, True, False):
            raise ValueError(Errors.E109.format(name=self.name))

    def pipe(self, stream, batch_size=128, n_threads=-1, as_example=False):
        """Apply the pipe to a stream of documents.

        Both __call__ and pipe should delegate to the `predict()`
        and `set_annotations()` methods.
        """
        for examples in util.minibatch(stream, size=batch_size):
            docs = [self._get_doc(ex) for ex in examples]
            predictions = self.predict(docs)
            if isinstance(predictions, tuple) and len(tuple) == 2:
                scores, tensors = predictions
                self.set_annotations(docs, scores, tensors=tensors)
            else:
                self.set_annotations(docs, predictions)

            if as_example:
                annotated_examples = []
                for ex, doc in zip(examples, docs):
                    ex.doc = doc
                    annotated_examples.append(ex)
                yield from annotated_examples
            else:
                yield from docs

    def predict(self, docs):
        """Apply the pipeline's model to a batch of docs, without
        modifying them.
        """
        self.require_model()
        raise NotImplementedError

    def set_annotations(self, docs, scores, tensors=None):
        """Modify a batch of documents, using pre-computed scores."""
        raise NotImplementedError

    def update(self, examples, set_annotations=False, drop=0.0, sgd=None, losses=None):
        """Learn from a batch of documents and gold-standard information,
        updating the pipe's model.

        Delegates to predict() and get_loss().
        """
        if set_annotations:
            docs = (self._get_doc(ex) for ex in examples)
            docs = list(self.pipe(docs))

    def rehearse(self, examples, sgd=None, losses=None, **config):
        pass

    def get_loss(self, examples, scores):
        """Find the loss and gradient of loss for the batch of
        examples (with embedded docs) and their predicted scores."""
        raise NotImplementedError

    def add_label(self, label):
        """Add an output label, to be predicted by the model.

        It's possible to extend pretrained models with new labels,
        but care should be taken to avoid the "catastrophic forgetting"
        problem.
        """
        raise NotImplementedError

    def create_optimizer(self):
        return create_default_optimizer(self.model.ops, **self.cfg.get("optimizer", {}))

    def begin_training(
        self, get_examples=lambda: [], pipeline=None, sgd=None, **kwargs
    ):
        """Initialize the pipe for training, using data exampes if available.
        If no model has been initialized yet, the model is added."""
        if self.model is True:
            self.model = self.Model(**self.cfg)
        if hasattr(self, "vocab"):
            link_vectors_to_models(self.vocab)
        if sgd is None:
            sgd = self.create_optimizer()
        return sgd

    def get_gradients(self):
        """Get non-zero gradients of the model's parameters, as a dictionary
        keyed by the parameter ID. The values are (weights, gradients) tuples.
        """
        gradients = {}
        if self.model in (None, True, False):
            return gradients
        queue = [self.model]
        seen = set()
        for node in queue:
            if node.id in seen:
                continue
            seen.add(node.id)
            if hasattr(node, "_mem") and node._mem.gradient.any():
                gradients[node.id] = [node._mem.weights, node._mem.gradient]
            if hasattr(node, "_layers"):
                queue.extend(node._layers)
        return gradients

    def use_params(self, params):
        """Modify the pipe's model, to use the given parameter values."""
        with self.model.use_params(params):
            yield

    def to_bytes(self, exclude=tuple(), **kwargs):
        """Serialize the pipe to a bytestring.

        exclude (list): String names of serialization fields to exclude.
        RETURNS (bytes): The serialized object.
        """
        serialize = {}
        serialize["cfg"] = lambda: srsly.json_dumps(self.cfg)
        if self.model not in (True, False, None):
            serialize["model"] = self.model.to_bytes
        if hasattr(self, "vocab"):
            serialize["vocab"] = self.vocab.to_bytes
        exclude = util.get_serialization_exclude(serialize, exclude, kwargs)
        return util.to_bytes(serialize, exclude)

    def from_bytes(self, bytes_data, exclude=tuple(), **kwargs):
        """Load the pipe from a bytestring."""

        def load_model(b):
            # TODO: Remove this once we don't have to handle previous models
            if self.cfg.get("pretrained_dims") and "pretrained_vectors" not in self.cfg:
                self.cfg["pretrained_vectors"] = self.vocab.vectors.name
            if self.model is True:
                self.model = self.Model(**self.cfg)
            try:
                self.model.from_bytes(b)
            except AttributeError:
                raise ValueError(Errors.E149)

        deserialize = {}
        deserialize["cfg"] = lambda b: self.cfg.update(srsly.json_loads(b))
        if hasattr(self, "vocab"):
            deserialize["vocab"] = lambda b: self.vocab.from_bytes(b)
        deserialize["model"] = load_model
        exclude = util.get_serialization_exclude(deserialize, exclude, kwargs)
        util.from_bytes(bytes_data, deserialize, exclude)
        return self

    def to_disk(self, path, exclude=tuple(), **kwargs):
        """Serialize the pipe to disk."""
        serialize = {}
        serialize["cfg"] = lambda p: srsly.write_json(p, self.cfg)
        serialize["vocab"] = lambda p: self.vocab.to_disk(p)
        if self.model not in (None, True, False):
            serialize["model"] = lambda p: p.open("wb").write(self.model.to_bytes())
        exclude = util.get_serialization_exclude(serialize, exclude, kwargs)
        util.to_disk(path, serialize, exclude)

    def from_disk(self, path, exclude=tuple(), **kwargs):
        """Load the pipe from disk."""

        def load_model(p):
            # TODO: Remove this once we don't have to handle previous models
            if self.cfg.get("pretrained_dims") and "pretrained_vectors" not in self.cfg:
                self.cfg["pretrained_vectors"] = self.vocab.vectors.name
            if self.model is True:
                self.model = self.Model(**self.cfg)
            try:
                self.model.from_bytes(p.open("rb").read())
            except AttributeError:
                raise ValueError(Errors.E149)

        deserialize = {}
        deserialize["cfg"] = lambda p: self.cfg.update(_load_cfg(p))
        deserialize["vocab"] = lambda p: self.vocab.from_disk(p)
        deserialize["model"] = load_model
        exclude = util.get_serialization_exclude(deserialize, exclude, kwargs)
        util.from_disk(path, deserialize, exclude)
        return self


@component("tensorizer", assigns=["doc.tensor"])
class Tensorizer(Pipe):
    """Pre-train position-sensitive vectors for tokens."""

    @classmethod
    def Model(cls, output_size=300, **cfg):
        """Create a new statistical model for the class.

        width (int): Output size of the model.
        embed_size (int): Number of vectors in the embedding table.
        **cfg: Config parameters.
        RETURNS (Model): A `thinc.model.Model` or similar instance.
        """
        input_size = util.env_opt("token_vector_width", cfg.get("input_size", 96))
        return Affine(output_size, input_size, init_W=zero_init)

    def __init__(self, vocab, model=True, **cfg):
        """Construct a new statistical model. Weights are not allocated on
        initialisation.

        vocab (Vocab): A `Vocab` instance. The model must share the same
            `Vocab` instance with the `Doc` objects it will process.
        model (Model): A `Model` instance or `True` to allocate one later.
        **cfg: Config parameters.

        EXAMPLE:
            >>> from spacy.pipeline import TokenVectorEncoder
            >>> tok2vec = TokenVectorEncoder(nlp.vocab)
            >>> tok2vec.model = tok2vec.Model(128, 5000)
        """
        self.vocab = vocab
        self.model = model
        self.input_models = []
        self.cfg = dict(cfg)
        self.cfg.setdefault("cnn_maxout_pieces", 3)

    def __call__(self, example):
        """Add context-sensitive vectors to a `Doc`, e.g. from a CNN or LSTM
        model. Vectors are set to the `Doc.tensor` attribute.

        docs (Doc or iterable): One or more documents to add vectors to.
        RETURNS (dict or None): Intermediate computations.
        """
        doc = self._get_doc(example)
        tokvecses = self.predict([doc])
        self.set_annotations([doc], tokvecses)
        if isinstance(example, Example):
            example.doc = doc
            return example
        return doc

    def pipe(self, stream, batch_size=128, n_threads=-1, as_example=False):
        """Process `Doc` objects as a stream.

        stream (iterator): A sequence of `Doc` or `Example` objects to process.
        batch_size (int): Number of `Doc` or `Example` objects to group.
        YIELDS (iterator): A sequence of `Doc` or `Example` objects, in order of input.
        """
        for examples in util.minibatch(stream, size=batch_size):
            docs = [self._get_doc(ex) for ex in examples]
            tensors = self.predict(docs)
            self.set_annotations(docs, tensors)

            if as_example:
                annotated_examples = []
                for ex, doc in zip(examples, docs):
                    ex.doc = doc
                    annotated_examples.append(ex)
                yield from annotated_examples
            else:
                yield from docs

    def predict(self, docs):
        """Return a single tensor for a batch of documents.

        docs (iterable): A sequence of `Doc` objects.
        RETURNS (object): Vector representations for each token in the docs.
        """
        self.require_model()
        inputs = self.model.ops.flatten([doc.tensor for doc in docs])
        outputs = self.model(inputs)
        return self.model.ops.unflatten(outputs, [len(d) for d in docs])

    def set_annotations(self, docs, tensors):
        """Set the tensor attribute for a batch of documents.

        docs (iterable): A sequence of `Doc` objects.
        tensors (object): Vector representation for each token in the docs.
        """
        for doc, tensor in zip(docs, tensors):
            if tensor.shape[0] != len(doc):
                raise ValueError(Errors.E076.format(rows=tensor.shape[0], words=len(doc)))
            doc.tensor = tensor

    def update(self, examples, state=None, drop=0.0, set_annotations=False, sgd=None, losses=None):
        """Update the model.

        docs (iterable): A batch of `Doc` objects.
        golds (iterable): A batch of `GoldParse` objects.
        drop (float): The dropout rate.
        sgd (callable): An optimizer.
        RETURNS (dict): Results from the update.
        """
        self.require_model()
        examples = Example.to_example_objects(examples)
        inputs = []
        bp_inputs = []
        self.model.set_dropout(drop)
        for tok2vec in self.input_models:
            tok2vec.set_dropout(drop)
            tensor, bp_tensor = tok2vec.begin_update([ex.doc for ex in examples])
            inputs.append(tensor)
            bp_inputs.append(bp_tensor)
        inputs = self.model.ops.xp.hstack(inputs)
        scores, bp_scores = self.model.begin_update(inputs)
        loss, d_scores = self.get_loss(examples, scores)
        d_inputs = bp_scores(d_scores, sgd=sgd)
        d_inputs = self.model.ops.xp.split(d_inputs, len(self.input_models), axis=1)
        for d_input, bp_input in zip(d_inputs, bp_inputs):
            bp_input(d_input)
        if sgd is not None:
            for tok2vec in self.input_models:
                tok2vec.finish_update(sgd)
            self.model.finish_update(sgd)
        if losses is not None:
            losses.setdefault(self.name, 0.0)
            losses[self.name] += loss
        return loss

    def get_loss(self, examples, prediction):
        examples = Example.to_example_objects(examples)
        ids = self.model.ops.flatten([ex.doc.to_array(ID).ravel() for ex in examples])
        target = self.vocab.vectors.data[ids]
        d_scores = (prediction - target) / prediction.shape[0]
        loss = (d_scores ** 2).sum()
        return loss, d_scores

    def begin_training(self, get_examples=lambda: [], pipeline=None, sgd=None, **kwargs):
        """Allocate models, pre-process training data and acquire an
        optimizer.

        get_examples (iterable): Gold-standard training data.
        pipeline (list): The pipeline the model is part of.
        """
        if pipeline is not None:
            for name, model in pipeline:
                if getattr(model, "tok2vec", None):
                    self.input_models.append(model.tok2vec)
        if self.model is True:
            self.model = self.Model(**self.cfg)
        link_vectors_to_models(self.vocab)
        if sgd is None:
            sgd = self.create_optimizer()
        return sgd


@component("tagger", assigns=["token.tag", "token.pos"])
class Tagger(Pipe):
    """Pipeline component for part-of-speech tagging.

    DOCS: https://spacy.io/api/tagger
    """

    def __init__(self, vocab, model=True, **cfg):
        self.vocab = vocab
        self.model = model
        self._rehearsal_model = None
        self.cfg = dict(sorted(cfg.items()))
        self.cfg.setdefault("cnn_maxout_pieces", 2)

    @property
    def labels(self):
        return tuple(self.vocab.morphology.tag_names)

    @property
    def tok2vec(self):
        if self.model in (None, True, False):
            return None
        else:
            return chain(self.model.get_ref("tok2vec"), list2array())

    def __call__(self, example):
        doc = self._get_doc(example)
        tags = self.predict([doc])
        self.set_annotations([doc], tags)
        if isinstance(example, Example):
            example.doc = doc
            return example
        return doc

    def pipe(self, stream, batch_size=128, n_threads=-1, as_example=False):
        for examples in util.minibatch(stream, size=batch_size):
            docs = [self._get_doc(ex) for ex in examples]
            tag_ids = self.predict(docs)
            assert len(docs) == len(examples)
            assert len(tag_ids) == len(examples)
            self.set_annotations(docs, tag_ids)

            if as_example:
                annotated_examples = []
                for ex, doc in zip(examples, docs):
                    ex.doc = doc
                    annotated_examples.append(ex)
                yield from annotated_examples
            else:
                yield from docs

    def predict(self, docs):
        self.require_model()
        if not any(len(doc) for doc in docs):
            # Handle cases where there are no tokens in any docs.
            n_labels = len(self.labels)
            guesses = [self.model.ops.allocate((0, n_labels)) for doc in docs]
            assert len(guesses) == len(docs)
            return guesses
        scores = self.model.predict(docs)
        assert len(scores) == len(docs), (len(scores), len(docs))
        guesses = self._scores2guesses(scores)
        assert len(guesses) == len(docs)
        return guesses

    def _scores2guesses(self, scores):
        guesses = []
        for doc_scores in scores:
            doc_guesses = doc_scores.argmax(axis=1)
            if not isinstance(doc_guesses, numpy.ndarray):
                doc_guesses = doc_guesses.get()
            guesses.append(doc_guesses)
        return guesses

    def set_annotations(self, docs, batch_tag_ids):
        if isinstance(docs, Doc):
            docs = [docs]
        cdef Doc doc
        cdef int idx = 0
        cdef Vocab vocab = self.vocab
        assign_morphology = self.cfg.get("set_morphology", True)
        for i, doc in enumerate(docs):
            doc_tag_ids = batch_tag_ids[i]
            if hasattr(doc_tag_ids, "get"):
                doc_tag_ids = doc_tag_ids.get()
            for j, tag_id in enumerate(doc_tag_ids):
                # Don't clobber preset POS tags
                if doc.c[j].tag == 0:
                    if doc.c[j].pos == 0 and assign_morphology:
                        # Don't clobber preset lemmas
                        lemma = doc.c[j].lemma
                        vocab.morphology.assign_tag_id(&doc.c[j], tag_id)
                        if lemma != 0 and lemma != doc.c[j].lex.orth:
                            doc.c[j].lemma = lemma
                    else:
                        doc.c[j].tag = self.vocab.strings[self.labels[tag_id]]
                idx += 1
            doc.is_tagged = True

    def update(self, examples, drop=0., sgd=None, losses=None, set_annotations=False):
        self.require_model()
        examples = Example.to_example_objects(examples)
        if losses is not None and self.name not in losses:
            losses[self.name] = 0.

        if not any(len(ex.doc) if ex.doc else 0 for ex in examples):
            # Handle cases where there are no tokens in any docs.
            return
        self.model.set_dropout(drop)
        tag_scores, bp_tag_scores = self.model.begin_update([ex.doc for ex in examples])
        loss, d_tag_scores = self.get_loss(examples, tag_scores)
        bp_tag_scores(d_tag_scores)
        if sgd is not None:
            self.model.finish_update(sgd)

        if losses is not None:
            losses[self.name] += loss
        if set_annotations:
            docs = [ex.doc for ex in examples]
            self.set_annotations(docs, self._scores2guesses(tag_scores))

    def rehearse(self, examples, drop=0., sgd=None, losses=None):
        """Perform a 'rehearsal' update, where we try to match the output of
        an initial model.
        """
        if self._rehearsal_model is None:
            return
        examples = Example.to_example_objects(examples)
        docs = [ex.doc for ex in examples]
        if not any(len(doc) for doc in docs):
            # Handle cases where there are no tokens in any docs.
            return
        self.model.set_dropout(drop)
        guesses, backprop = self.model.begin_update(docs)
        target = self._rehearsal_model(examples)
        gradient = guesses - target
        backprop(gradient)
        self.model.finish_update(sgd)
        if losses is not None:
            losses.setdefault(self.name, 0.0)
            losses[self.name] += (gradient**2).sum()

    def get_loss(self, examples, scores):
        scores = self.model.ops.flatten(scores)
        tag_index = {tag: i for i, tag in enumerate(self.labels)}
        cdef int idx = 0
        correct = numpy.zeros((scores.shape[0],), dtype="i")
        guesses = scores.argmax(axis=1)
        known_labels = numpy.ones((scores.shape[0], 1), dtype="f")
        for ex in examples:
            gold = ex.gold
            for tag in gold.tags:
                if tag is None:
                    correct[idx] = guesses[idx]
                elif tag in tag_index:
                    correct[idx] = tag_index[tag]
                else:
                    correct[idx] = 0
                    known_labels[idx] = 0.
                idx += 1
        correct = self.model.ops.xp.array(correct, dtype="i")
        d_scores = scores - to_categorical(correct, nb_classes=scores.shape[1])
        d_scores *= self.model.ops.asarray(known_labels)
        loss = (d_scores**2).sum()
        docs = [ex.doc for ex in examples]
        d_scores = self.model.ops.unflatten(d_scores, [len(d) for d in docs])
        return float(loss), d_scores

    def begin_training(self, get_examples=lambda: [], pipeline=None, sgd=None,
                       **kwargs):
        lemma_tables = ["lemma_rules", "lemma_index", "lemma_exc", "lemma_lookup"]
        if not any(table in self.vocab.lookups for table in lemma_tables):
            user_warning(Warnings.W022)
        orig_tag_map = dict(self.vocab.morphology.tag_map)
        new_tag_map = {}
        for example in get_examples():
            for tag in example.token_annotation.tags:
                if tag in orig_tag_map:
                    new_tag_map[tag] = orig_tag_map[tag]
                else:
                    new_tag_map[tag] = {POS: X}
        cdef Vocab vocab = self.vocab
        if new_tag_map:
            vocab.morphology = Morphology(vocab.strings, new_tag_map,
                                          vocab.morphology.lemmatizer,
                                          exc=vocab.morphology.exc)
        self.cfg["pretrained_vectors"] = kwargs.get("pretrained_vectors")
        if self.model is True:
            for hp in ["token_vector_width", "conv_depth"]:
                if hp in kwargs:
                    self.cfg[hp] = kwargs[hp]
            self.model = self.Model(self.vocab.morphology.n_tags, **self.cfg)
        # Get batch of example docs, example outputs to call begin_training().
        # This lets the model infer shapes.
        n_tags = self.vocab.morphology.n_tags
        for node in self.model.walk():
            if node.name == "softmax" and node.nO == None:
                node.nO = n_tags
        link_vectors_to_models(self.vocab)
        if sgd is None:
            sgd = self.create_optimizer()
        return sgd

    @classmethod
    def Model(cls, n_tags, **cfg):
        if cfg.get("pretrained_dims") and not cfg.get("pretrained_vectors"):
            raise ValueError(TempErrors.T008)
        return build_tagger_model(n_tags, **cfg)

    def add_label(self, label, values=None):
        if not isinstance(label, str):
            raise ValueError(Errors.E187)
        if label in self.labels:
            return 0
        if self.model not in (True, False, None):
            # Here's how the model resizing will work, once the
            # neuron-to-tag mapping is no longer controlled by
            # the Morphology class, which sorts the tag names.
            # The sorting makes adding labels difficult.
            # smaller = self.model._layers[-1]
            # larger = Softmax(len(self.labels)+1, smaller.nI)
            # copy_array(larger.W[:smaller.nO], smaller.W)
            # copy_array(larger.b[:smaller.nO], smaller.b)
            # self.model._layers[-1] = larger
            raise ValueError(TempErrors.T003)
        tag_map = dict(self.vocab.morphology.tag_map)
        if values is None:
            values = {POS: "X"}
        tag_map[label] = values
        self.vocab.morphology = Morphology(
            self.vocab.strings, tag_map=tag_map,
            lemmatizer=self.vocab.morphology.lemmatizer,
            exc=self.vocab.morphology.exc)
        return 1

    def use_params(self, params):
        with self.model.use_params(params):
            yield

    def to_bytes(self, exclude=tuple(), **kwargs):
        serialize = {}
        if self.model not in (None, True, False):
            serialize["model"] = self.model.to_bytes
        serialize["vocab"] = self.vocab.to_bytes
        serialize["cfg"] = lambda: srsly.json_dumps(self.cfg)
        tag_map = dict(sorted(self.vocab.morphology.tag_map.items()))
        serialize["tag_map"] = lambda: srsly.msgpack_dumps(tag_map)
        exclude = util.get_serialization_exclude(serialize, exclude, kwargs)
        return util.to_bytes(serialize, exclude)

    def from_bytes(self, bytes_data, exclude=tuple(), **kwargs):
        def load_model(b):
            # TODO: Remove this once we don't have to handle previous models
            if self.cfg.get("pretrained_dims") and "pretrained_vectors" not in self.cfg:
                self.cfg["pretrained_vectors"] = self.vocab.vectors.name
            if self.model is True:
                token_vector_width = util.env_opt(
                    "token_vector_width",
                    self.cfg.get("token_vector_width", 96))
                self.model = self.Model(self.vocab.morphology.n_tags, **self.cfg)
            try:
                self.model.from_bytes(b)
            except AttributeError:
                raise ValueError(Errors.E149)

        def load_tag_map(b):
            tag_map = srsly.msgpack_loads(b)
            self.vocab.morphology = Morphology(
                self.vocab.strings, tag_map=tag_map,
                lemmatizer=self.vocab.morphology.lemmatizer,
                exc=self.vocab.morphology.exc)

        deserialize = {
            "vocab": lambda b: self.vocab.from_bytes(b),
            "tag_map": load_tag_map,
            "cfg": lambda b: self.cfg.update(srsly.json_loads(b)),
            "model": lambda b: load_model(b),
        }
        exclude = util.get_serialization_exclude(deserialize, exclude, kwargs)
        util.from_bytes(bytes_data, deserialize, exclude)
        return self

    def to_disk(self, path, exclude=tuple(), **kwargs):
        tag_map = dict(sorted(self.vocab.morphology.tag_map.items()))
        serialize = {
            "vocab": lambda p: self.vocab.to_disk(p),
            "tag_map": lambda p: srsly.write_msgpack(p, tag_map),
            "model": lambda p: p.open("wb").write(self.model.to_bytes()),
            "cfg": lambda p: srsly.write_json(p, self.cfg)
        }
        exclude = util.get_serialization_exclude(serialize, exclude, kwargs)
        util.to_disk(path, serialize, exclude)

    def from_disk(self, path, exclude=tuple(), **kwargs):
        def load_model(p):
            # TODO: Remove this once we don't have to handle previous models
            if self.cfg.get("pretrained_dims") and "pretrained_vectors" not in self.cfg:
                self.cfg["pretrained_vectors"] = self.vocab.vectors.name
            if self.model is True:
                self.model = self.Model(self.vocab.morphology.n_tags, **self.cfg)
            with p.open("rb") as file_:
                try:
                    self.model.from_bytes(file_.read())
                except AttributeError:
                    raise ValueError(Errors.E149)

        def load_tag_map(p):
            tag_map = srsly.read_msgpack(p)
            self.vocab.morphology = Morphology(
                self.vocab.strings, tag_map=tag_map,
                lemmatizer=self.vocab.morphology.lemmatizer,
                exc=self.vocab.morphology.exc)

        deserialize = {
            "cfg": lambda p: self.cfg.update(_load_cfg(p)),
            "vocab": lambda p: self.vocab.from_disk(p),
            "tag_map": load_tag_map,
            "model": load_model,
        }
        exclude = util.get_serialization_exclude(deserialize, exclude, kwargs)
        util.from_disk(path, deserialize, exclude)
        return self


@component("sentrec", assigns=["token.is_sent_start"])
class SentenceRecognizer(Tagger):
    """Pipeline component for sentence segmentation.

    DOCS: https://spacy.io/api/sentencerecognizer
    """

    def __init__(self, vocab, model=True, **cfg):
        self.vocab = vocab
        self.model = model
        self._rehearsal_model = None
        self.cfg = dict(sorted(cfg.items()))
        self.cfg.setdefault("cnn_maxout_pieces", 2)
        self.cfg.setdefault("subword_features", True)
        self.cfg.setdefault("token_vector_width", 12)
        self.cfg.setdefault("conv_depth", 1)
        self.cfg.setdefault("pretrained_vectors", None)

    @property
    def labels(self):
        # labels are numbered by index internally, so this matches GoldParse
        # and Example where the sentence-initial tag is 1 and other positions
        # are 0
        return tuple(["I", "S"])

    def set_annotations(self, docs, batch_tag_ids, **_):
        if isinstance(docs, Doc):
            docs = [docs]
        cdef Doc doc
        for i, doc in enumerate(docs):
            doc_tag_ids = batch_tag_ids[i]
            if hasattr(doc_tag_ids, "get"):
                doc_tag_ids = doc_tag_ids.get()
            for j, tag_id in enumerate(doc_tag_ids):
                # Don't clobber existing sentence boundaries
                if doc.c[j].sent_start == 0:
                    if tag_id == 1:
                        doc.c[j].sent_start = 1
                    else:
                        doc.c[j].sent_start = -1

    def update(self, examples, drop=0., sgd=None, losses=None):
        self.require_model()
        examples = Example.to_example_objects(examples)
        if losses is not None and self.name not in losses:
            losses[self.name] = 0.

        if not any(len(ex.doc) if ex.doc else 0 for ex in examples):
            # Handle cases where there are no tokens in any docs.
            return
        self.model.set_dropout(drop)
        tag_scores, bp_tag_scores = self.model.begin_update([ex.doc for ex in examples])
        loss, d_tag_scores = self.get_loss(examples, tag_scores)
        bp_tag_scores(d_tag_scores)
        if sgd is not None:
            self.model.finish_update(sgd)

        if losses is not None:
            losses[self.name] += loss

    def get_loss(self, examples, scores):
        scores = self.model.ops.flatten(scores)
        tag_index = range(len(self.labels))
        cdef int idx = 0
        correct = numpy.zeros((scores.shape[0],), dtype="i")
        guesses = scores.argmax(axis=1)
        known_labels = numpy.ones((scores.shape[0], 1), dtype="f")
        for ex in examples:
            gold = ex.gold
            for sent_start in gold.sent_starts:
                if sent_start is None:
                    correct[idx] = guesses[idx]
                elif sent_start in tag_index:
                    correct[idx] = sent_start
                else:
                    correct[idx] = 0
                    known_labels[idx] = 0.
                idx += 1
        correct = self.model.ops.xp.array(correct, dtype="i")
        d_scores = scores - to_categorical(correct, nb_classes=scores.shape[1])
        d_scores *= self.model.ops.asarray(known_labels)
        loss = (d_scores**2).sum()
        docs = [ex.doc for ex in examples]
        d_scores = self.model.ops.unflatten(d_scores, [len(d) for d in docs])
        return float(loss), d_scores

    def begin_training(self, get_examples=lambda: [], pipeline=None, sgd=None,
                       **kwargs):
        cdef Vocab vocab = self.vocab
        if self.model is True:
            for hp in ["token_vector_width", "conv_depth"]:
                if hp in kwargs:
                    self.cfg[hp] = kwargs[hp]
            self.model = self.Model(len(self.labels), **self.cfg)
        if sgd is None:
            sgd = self.create_optimizer()
        return sgd

    @classmethod
    def Model(cls, n_tags, **cfg):
        return build_tagger_model(n_tags, **cfg)

    def add_label(self, label, values=None):
        raise NotImplementedError

    def use_params(self, params):
        with self.model.use_params(params):
            yield

    def to_bytes(self, exclude=tuple(), **kwargs):
        serialize = {}
        if self.model not in (None, True, False):
            serialize["model"] = self.model.to_bytes
        serialize["vocab"] = self.vocab.to_bytes
        serialize["cfg"] = lambda: srsly.json_dumps(self.cfg)
        exclude = util.get_serialization_exclude(serialize, exclude, kwargs)
        return util.to_bytes(serialize, exclude)

    def from_bytes(self, bytes_data, exclude=tuple(), **kwargs):
        def load_model(b):
            if self.model is True:
                self.model = self.Model(len(self.labels), **self.cfg)
            try:
                self.model.from_bytes(b)
            except AttributeError:
                raise ValueError(Errors.E149)

        deserialize = {
            "vocab": lambda b: self.vocab.from_bytes(b),
            "cfg": lambda b: self.cfg.update(srsly.json_loads(b)),
            "model": lambda b: load_model(b),
        }
        exclude = util.get_serialization_exclude(deserialize, exclude, kwargs)
        util.from_bytes(bytes_data, deserialize, exclude)
        return self

    def to_disk(self, path, exclude=tuple(), **kwargs):
        serialize = {
            "vocab": lambda p: self.vocab.to_disk(p),
            "model": lambda p: p.open("wb").write(self.model.to_bytes()),
            "cfg": lambda p: srsly.write_json(p, self.cfg)
        }
        exclude = util.get_serialization_exclude(serialize, exclude, kwargs)
        util.to_disk(path, serialize, exclude)

    def from_disk(self, path, exclude=tuple(), **kwargs):
        def load_model(p):
            if self.model is True:
                self.model = self.Model(len(self.labels), **self.cfg)
            with p.open("rb") as file_:
                try:
                    self.model.from_bytes(file_.read())
                except AttributeError:
                    raise ValueError(Errors.E149)

        deserialize = {
            "cfg": lambda p: self.cfg.update(_load_cfg(p)),
            "vocab": lambda p: self.vocab.from_disk(p),
            "model": load_model,
        }
        exclude = util.get_serialization_exclude(deserialize, exclude, kwargs)
        util.from_disk(path, deserialize, exclude)
        return self


@component("nn_labeller")
class MultitaskObjective(Tagger):
    """Experimental: Assist training of a parser or tagger, by training a
    side-objective.
    """

    def __init__(self, vocab, model=True, target='dep_tag_offset', **cfg):
        self.vocab = vocab
        self.model = model
        if target == "dep":
            self.make_label = self.make_dep
        elif target == "tag":
            self.make_label = self.make_tag
        elif target == "ent":
            self.make_label = self.make_ent
        elif target == "dep_tag_offset":
            self.make_label = self.make_dep_tag_offset
        elif target == "ent_tag":
            self.make_label = self.make_ent_tag
        elif target == "sent_start":
            self.make_label = self.make_sent_start
        elif hasattr(target, "__call__"):
            self.make_label = target
        else:
            raise ValueError(Errors.E016)
        self.cfg = dict(cfg)
        self.cfg.setdefault("cnn_maxout_pieces", 2)

    @property
    def labels(self):
        return self.cfg.setdefault("labels", {})

    @labels.setter
    def labels(self, value):
        self.cfg["labels"] = value

    def set_annotations(self, docs, dep_ids, tensors=None):
        pass

    def begin_training(self, get_examples=lambda: [], pipeline=None, tok2vec=None,
                       sgd=None, **kwargs):
        gold_examples = nonproj.preprocess_training_data(get_examples())
        # for raw_text, doc_annot in gold_tuples:
        for example in gold_examples:
            for i in range(len(example.token_annotation.ids)):
                label = self.make_label(i, example.token_annotation)
                if label is not None and label not in self.labels:
                    self.labels[label] = len(self.labels)
        if self.model is True:
            token_vector_width = util.env_opt("token_vector_width")
            self.model = self.Model(len(self.labels), tok2vec=tok2vec)
        link_vectors_to_models(self.vocab)
        if sgd is None:
            sgd = self.create_optimizer()
        return sgd

    @classmethod
    def Model(cls, n_tags, tok2vec=None, **cfg):
        token_vector_width = util.env_opt("token_vector_width", 96)
        model = chain(
            tok2vec,
            LayerNorm(Maxout(token_vector_width*2, token_vector_width, pieces=3)),
            Softmax(n_tags, token_vector_width*2)
        )
        return model

    def predict(self, docs):
        self.require_model()
        tokvecs = self.model.tok2vec(docs)
        scores = self.model.softmax(tokvecs)
        return tokvecs, scores

    def get_loss(self, examples, scores):
        cdef int idx = 0
        correct = numpy.zeros((scores.shape[0],), dtype="i")
        guesses = scores.argmax(axis=1)
        golds = [ex.gold for ex in examples]
        docs = [ex.doc for ex in examples]
        for i, gold in enumerate(golds):
            for j in range(len(docs[i])):
                # Handels alignment for tokenization differences
                token_annotation = gold.get_token_annotation()
                label = self.make_label(j, token_annotation)
                if label is None or label not in self.labels:
                    correct[idx] = guesses[idx]
                else:
                    correct[idx] = self.labels[label]
                idx += 1
        correct = self.model.ops.xp.array(correct, dtype="i")
        d_scores = scores - to_categorical(correct, nb_classes=scores.shape[1])
        loss = (d_scores**2).sum()
        return float(loss), d_scores

    @staticmethod
    def make_dep(i, token_annotation):
        if token_annotation.deps[i] is None or token_annotation.heads[i] is None:
            return None
        return token_annotation.deps[i]

    @staticmethod
    def make_tag(i, token_annotation):
        return token_annotation.tags[i]

    @staticmethod
    def make_ent(i, token_annotation):
        if token_annotation.entities is None:
            return None
        return token_annotation.entities[i]

    @staticmethod
    def make_dep_tag_offset(i, token_annotation):
        if token_annotation.deps[i] is None or token_annotation.heads[i] is None:
            return None
        offset = token_annotation.heads[i] - i
        offset = min(offset, 2)
        offset = max(offset, -2)
        return "%s-%s:%d" % (token_annotation.deps[i], token_annotation.tags[i], offset)

    @staticmethod
    def make_ent_tag(i, token_annotation):
        if token_annotation.entities is None or token_annotation.entities[i] is None:
            return None
        else:
            return "%s-%s" % (token_annotation.tags[i], token_annotation.entities[i])

    @staticmethod
    def make_sent_start(target, token_annotation, cache=True, _cache={}):
        """A multi-task objective for representing sentence boundaries,
        using BILU scheme. (O is impossible)

        The implementation of this method uses an internal cache that relies
        on the identity of the heads array, to avoid requiring a new piece
        of gold data. You can pass cache=False if you know the cache will
        do the wrong thing.
        """
        words = token_annotation.words
        heads = token_annotation.heads
        assert len(words) == len(heads)
        assert target < len(words), (target, len(words))
        if cache:
            if id(heads) in _cache:
                return _cache[id(heads)][target]
            else:
                for key in list(_cache.keys()):
                    _cache.pop(key)
            sent_tags = ["I-SENT"] * len(words)
            _cache[id(heads)] = sent_tags
        else:
            sent_tags = ["I-SENT"] * len(words)

        def _find_root(child):
            seen = set([child])
            while child is not None and heads[child] != child:
                seen.add(child)
                child = heads[child]
            return child

        sentences = {}
        for i in range(len(words)):
            root = _find_root(i)
            if root is None:
                sent_tags[i] = None
            else:
                sentences.setdefault(root, []).append(i)
        for root, span in sorted(sentences.items()):
            if len(span) == 1:
                sent_tags[span[0]] = "U-SENT"
            else:
                sent_tags[span[0]] = "B-SENT"
                sent_tags[span[-1]] = "L-SENT"
        return sent_tags[target]


class ClozeMultitask(Pipe):
    @classmethod
    def Model(cls, vocab, tok2vec, **cfg):
        output_size = vocab.vectors.data.shape[1]
        output_layer = chain(
            Maxout(output_size, tok2vec.nO, pieces=3, normalize=True),
            Affine(output_size, output_size, init_W=zero_init)
        )
        model = chain(tok2vec, output_layer)
        model = masked_language_model(vocab, model)
        return model

    def __init__(self, vocab, model=True, **cfg):
        self.vocab = vocab
        self.model = model
        self.cfg = cfg

    def set_annotations(self, docs, dep_ids, tensors=None):
        pass

    def begin_training(self, get_examples=lambda: [], pipeline=None,
                        tok2vec=None, sgd=None, **kwargs):
        link_vectors_to_models(self.vocab)
        if self.model is True:
            self.model = self.Model(self.vocab, tok2vec)
        X = self.model.ops.allocate((5, self.model.tok2vec.nO))
        self.model.output_layer.begin_training(X)
        if sgd is None:
            sgd = self.create_optimizer()
        return sgd

    def predict(self, docs):
        self.require_model()
        tokvecs = self.model.tok2vec(docs)
        vectors = self.model.output_layer(tokvecs)
        return tokvecs, vectors

    def get_loss(self, examples, vectors, prediction):
        # The simplest way to implement this would be to vstack the
        # token.vector values, but that's a bit inefficient, especially on GPU.
        # Instead we fetch the index into the vectors table for each of our tokens,
        # and look them up all at once. This prevents data copying.
        ids = self.model.ops.flatten([ex.doc.to_array(ID).ravel() for ex in examples])
        target = vectors[ids]
        loss, gradient = cosine_distance(prediction, target, ignore_zeros=True)
        return float(loss), gradient

    def update(self, examples, drop=0., set_annotations=False, sgd=None, losses=None):
        pass

    def rehearse(self, examples, drop=0., sgd=None, losses=None):
        self.require_model()
        examples = Example.to_example_objects(examples)
        if losses is not None and self.name not in losses:
            losses[self.name] = 0.
        self.model.set_dropout(drop)
        predictions, bp_predictions = self.model.begin_update([ex.doc for ex in examples])
        loss, d_predictions = self.get_loss(examples, self.vocab.vectors.data, predictions)
        bp_predictions(d_predictions)
        if sgd is not None:
            self.model.finish_update(sgd)

        if losses is not None:
            losses[self.name] += loss


@component("textcat", assigns=["doc.cats"])
class TextCategorizer(Pipe):
    """Pipeline component for text classification.

    DOCS: https://spacy.io/api/textcategorizer
    """

    @classmethod
    def Model(cls, nr_class=1, **cfg):
        embed_size = util.env_opt("embed_size", 2000)
        if "token_vector_width" in cfg:
            token_vector_width = cfg["token_vector_width"]
        else:
            token_vector_width = util.env_opt("token_vector_width", 96)
        if cfg.get("architecture") == "simple_cnn":
            tok2vec = Tok2Vec(token_vector_width, embed_size, **cfg)
            return build_simple_cnn_text_classifier(tok2vec, nr_class, **cfg)
        elif cfg.get("architecture") == "bow":
            return build_bow_text_classifier(nr_class, **cfg)
        else:
            return build_text_classifier(nr_class, **cfg)

    @property
    def tok2vec(self):
        if self.model in (None, True, False):
            return None
        else:
            return self.model.tok2vec

    def __init__(self, vocab, model=True, **cfg):
        self.vocab = vocab
        self.model = model
        self._rehearsal_model = None
        self.cfg = dict(cfg)

    @property
    def labels(self):
        return tuple(self.cfg.setdefault("labels", []))

    def require_labels(self):
        """Raise an error if the component's model has no labels defined."""
        if not self.labels:
            raise ValueError(Errors.E143.format(name=self.name))

    @labels.setter
    def labels(self, value):
        self.cfg["labels"] = tuple(value)

    def pipe(self, stream, batch_size=128, n_threads=-1, as_example=False):
        for examples in util.minibatch(stream, size=batch_size):
            docs = [self._get_doc(ex) for ex in examples]
            scores, tensors = self.predict(docs)
            self.set_annotations(docs, scores, tensors=tensors)

            if as_example:
                annotated_examples = []
                for ex, doc in zip(examples, docs):
                    ex.doc = doc
                    annotated_examples.append(ex)
                yield from annotated_examples
            else:
                yield from docs

    def predict(self, docs):
        self.require_model()
        tensors = [doc.tensor for doc in docs]

        if not any(len(doc) for doc in docs):
            # Handle cases where there are no tokens in any docs.
            xp = get_array_module(tensors)
            scores = xp.zeros((len(docs), len(self.labels)))
            return scores, tensors

        scores = self.model(docs)
        scores = self.model.ops.asarray(scores)
        return scores, tensors

    def set_annotations(self, docs, scores, tensors=None):
        for i, doc in enumerate(docs):
            for j, label in enumerate(self.labels):
                doc.cats[label] = float(scores[i, j])

    def update(self, examples, state=None, drop=0., set_annotations=False, sgd=None, losses=None):
        self.require_model()
        examples = Example.to_example_objects(examples)
        if not any(len(ex.doc) if ex.doc else 0 for ex in examples):
            # Handle cases where there are no tokens in any docs.
            return
        self.model.set_dropout(drop)
        scores, bp_scores = self.model.begin_update([ex.doc for ex in examples])
        loss, d_scores = self.get_loss(examples, scores)
        bp_scores(d_scores)
        if sgd is not None:
            self.model.finish_update(sgd)
        if losses is not None:
            losses.setdefault(self.name, 0.0)
            losses[self.name] += loss
        if set_annotations:
            docs = [ex.doc for ex in examples]
            self.set_annotations(docs, scores=scores)

    def rehearse(self, examples, drop=0., sgd=None, losses=None):
        if self._rehearsal_model is None:
            return
        examples = Example.to_example_objects(examples)
        docs=[ex.doc for ex in examples]
        if not any(len(doc) for doc in docs):
            # Handle cases where there are no tokens in any docs.
            return
        self.model.set_dropout(drop)
        scores, bp_scores = self.model.begin_update(docs)
        target = self._rehearsal_model(examples)
        gradient = scores - target
        bp_scores(gradient)
        if sgd is not None:
            self.model.finish_update(sgd)
        if losses is not None:
            losses.setdefault(self.name, 0.0)
            losses[self.name] += (gradient**2).sum()

    def get_loss(self, examples, scores):
        golds = [ex.gold for ex in examples]
        truths = numpy.zeros((len(golds), len(self.labels)), dtype="f")
        not_missing = numpy.ones((len(golds), len(self.labels)), dtype="f")
        for i, gold in enumerate(golds):
            for j, label in enumerate(self.labels):
                if label in gold.cats:
                    truths[i, j] = gold.cats[label]
                else:
                    not_missing[i, j] = 0.
        truths = self.model.ops.asarray(truths)
        not_missing = self.model.ops.asarray(not_missing)
        d_scores = (scores-truths) / scores.shape[0]
        d_scores *= not_missing
        mean_square_error = (d_scores**2).sum(axis=1).mean()
        return float(mean_square_error), d_scores

    def add_label(self, label):
        if not isinstance(label, str):
            raise ValueError(Errors.E187)
        if label in self.labels:
            return 0
        if self.model not in (None, True, False):
            # This functionality was available previously, but was broken.
            # The problem is that we resize the last layer, but the last layer
            # is actually just an ensemble. We're not resizing the child layers
            # - a huge problem.
            raise ValueError(Errors.E116)
            # smaller = self.model._layers[-1]
            # larger = Affine(len(self.labels)+1, smaller.nI)
            # copy_array(larger.W[:smaller.nO], smaller.W)
            # copy_array(larger.b[:smaller.nO], smaller.b)
            # self.model._layers[-1] = larger
        self.labels = tuple(list(self.labels) + [label])
        return 1

    def begin_training(self, get_examples=lambda: [], pipeline=None, sgd=None, **kwargs):
        for example in get_examples():
            for cat in example.doc_annotation.cats:
                self.add_label(cat)
        if self.model is True:
            self.cfg["pretrained_vectors"] = kwargs.get("pretrained_vectors")
            self.require_labels()
            self.model = self.Model(len(self.labels), **self.cfg)
            link_vectors_to_models(self.vocab)
        if sgd is None:
            sgd = self.create_optimizer()
        return sgd


cdef class DependencyParser(Parser):
    """Pipeline component for dependency parsing.

    DOCS: https://spacy.io/api/dependencyparser
    """
    # cdef classes can't have decorators, so we're defining this here
    name = "parser"
    factory = "parser"
    assigns = ["token.dep", "token.is_sent_start", "doc.sents"]
    requires = []
    TransitionSystem = ArcEager

    @property
    def postprocesses(self):
        output = [nonproj.deprojectivize]
        if self.cfg.get("learn_tokens") is True:
            output.append(merge_subtokens)
        return tuple(output)

    def add_multitask_objective(self, target):
        if target == "cloze":
            cloze = ClozeMultitask(self.vocab)
            self._multitasks.append(cloze)
        else:
            labeller = MultitaskObjective(self.vocab, target=target)
            self._multitasks.append(labeller)

    def init_multitask_objectives(self, get_examples, pipeline, sgd=None, **cfg):
        for labeller in self._multitasks:
            tok2vec = self.model.tok2vec
            labeller.begin_training(get_examples, pipeline=pipeline,
                                    tok2vec=tok2vec, sgd=sgd)

    def __reduce__(self):
        return (DependencyParser, (self.vocab, self.moves, self.model), None, None)

    @property
    def labels(self):
        labels = set()
        # Get the labels from the model by looking at the available moves
        for move in self.move_names:
            if "-" in move:
                label = move.split("-")[1]
                if "||" in label:
                    label = label.split("||")[1]
                labels.add(label)
        return tuple(sorted(labels))


cdef class EntityRecognizer(Parser):
    """Pipeline component for named entity recognition.

    DOCS: https://spacy.io/api/entityrecognizer
    """
    name = "ner"
    factory = "ner"
    assigns = ["doc.ents", "token.ent_iob", "token.ent_type"]
    requires = []
    TransitionSystem = BiluoPushDown
    nr_feature = 6

    def add_multitask_objective(self, target):
        if target == "cloze":
            cloze = ClozeMultitask(self.vocab)
            self._multitasks.append(cloze)
        else:
            labeller = MultitaskObjective(self.vocab, target=target)
            self._multitasks.append(labeller)

    def init_multitask_objectives(self, get_examples, pipeline, sgd=None, **cfg):
        for labeller in self._multitasks:
            tok2vec = self.model.tok2vec
            labeller.begin_training(get_examples, pipeline=pipeline,
                                    tok2vec=tok2vec)

    def __reduce__(self):
        return (EntityRecognizer, (self.vocab, self.moves, self.model),
                None, None)

    @property
    def labels(self):
        # Get the labels from the model by looking at the available moves, e.g.
        # B-PERSON, I-PERSON, L-PERSON, U-PERSON
        labels = set(move.split("-")[1] for move in self.move_names
                     if move[0] in ("B", "I", "L", "U"))
        return tuple(sorted(labels))


@component(
    "entity_linker",
    requires=["doc.ents", "doc.sents", "token.ent_iob", "token.ent_type"],
    assigns=["token.ent_kb_id"]
)
class EntityLinker(Pipe):
    """Pipeline component for named entity linking.

    DOCS: https://spacy.io/api/entitylinker
    """
    NIL = "NIL"  # string used to refer to a non-existing link

    @classmethod
    def Model(cls, **cfg):
        embed_width = cfg.get("embed_width", 300)
        hidden_width = cfg.get("hidden_width", 128)
        type_to_int = cfg.get("type_to_int", dict())

        model = build_nel_encoder(embed_width=embed_width, hidden_width=hidden_width, ner_types=len(type_to_int), **cfg)
        return model

    def __init__(self, vocab, **cfg):
        self.vocab = vocab
        self.model = True
        self.kb = None
        self.cfg = dict(cfg)

    def set_kb(self, kb):
        self.kb = kb

    def require_model(self):
        # Raise an error if the component's model is not initialized.
        if getattr(self, "model", None) in (None, True, False):
            raise ValueError(Errors.E109.format(name=self.name))

    def require_kb(self):
        # Raise an error if the knowledge base is not initialized.
        if getattr(self, "kb", None) in (None, True, False):
            raise ValueError(Errors.E139.format(name=self.name))

    def begin_training(self, get_examples=lambda: [], pipeline=None, sgd=None, **kwargs):
        self.require_kb()
        self.cfg["entity_width"] = self.kb.entity_vector_length

        if self.model is True:
            self.model = self.Model(**self.cfg)

        if sgd is None:
            sgd = self.create_optimizer()

        return sgd

    def update(self, examples, state=None, set_annotations=False, drop=0.0, sgd=None, losses=None):
        self.require_model()
        self.require_kb()
        if losses is not None:
            losses.setdefault(self.name, 0.0)
        if not examples:
            return 0
        examples = Example.to_example_objects(examples)
        sentence_docs = []
        docs = [ex.doc for ex in examples]
        if set_annotations:
            # This seems simpler than other ways to get that exact output -- but
            # it does run the model twice :(
            predictions = self.model.predict(docs)
        golds = [ex.gold for ex in examples]

        for doc, gold in zip(docs, golds):
            ents_by_offset = dict()
            for ent in doc.ents:
                ents_by_offset[(ent.start_char, ent.end_char)] = ent

            for entity, kb_dict in gold.links.items():
                start, end = entity
                mention = doc.text[start:end]

                # the gold annotations should link to proper entities - if this fails, the dataset is likely corrupt
                if not (start, end) in ents_by_offset:
                    raise RuntimeError(Errors.E188)
                ent = ents_by_offset[(start, end)]

                for kb_id, value in kb_dict.items():
                    # Currently only training on the positive instances - we assume there is at least 1 per doc/gold
                    if value:
                        try:
                            sentence_docs.append(ent.sent.as_doc())
                        except AttributeError:
                            # Catch the exception when ent.sent is None and provide a user-friendly warning
                            raise RuntimeError(Errors.E030)
        self.model.set_dropout(drop)
        sentence_encodings, bp_context = self.model.begin_update(sentence_docs)
        loss, d_scores = self.get_similarity_loss(scores=sentence_encodings, golds=golds)
        bp_context(d_scores)
        if sgd is not None:
            self.model.finish_update(sgd)

        if losses is not None:
            losses[self.name] += loss
        if set_annotations:
            self.set_annotations(docs, predictions)
        return loss

    def get_similarity_loss(self, golds, scores):
        entity_encodings = []
        for gold in golds:
            for entity, kb_dict in gold.links.items():
                for kb_id, value in kb_dict.items():
                    # this loss function assumes we're only using positive examples
                    if value:
                        entity_encoding = self.kb.get_vector(kb_id)
                        entity_encodings.append(entity_encoding)

        entity_encodings = self.model.ops.asarray(entity_encodings, dtype="float32")

        if scores.shape != entity_encodings.shape:
            raise RuntimeError(Errors.E147.format(method="get_similarity_loss", msg="gold entities do not match up"))

        loss, gradients = cosine_distance(yh=scores, y=entity_encodings)
        loss = loss / len(entity_encodings)
        return loss, gradients

    def get_loss(self, examples, scores):
        cats = []
        for ex in examples:
            for entity, kb_dict in ex.gold.links.items():
                for kb_id, value in kb_dict.items():
                    cats.append([value])

        cats = self.model.ops.asarray(cats, dtype="float32")
        if len(scores) != len(cats):
            raise RuntimeError(Errors.E147.format(method="get_loss", msg="gold entities do not match up"))

        d_scores = (scores - cats)
        loss = (d_scores ** 2).sum()
        loss = loss / len(cats)
        return loss, d_scores

    def __call__(self, example):
        doc = self._get_doc(example)
        kb_ids, tensors = self.predict([doc])
        self.set_annotations([doc], kb_ids, tensors=tensors)
        if isinstance(example, Example):
            example.doc = doc
            return example
        return doc

    def pipe(self, stream, batch_size=128, n_threads=-1, as_example=False):
        for examples in util.minibatch(stream, size=batch_size):
            docs = [self._get_doc(ex) for ex in examples]
            kb_ids, tensors = self.predict(docs)
            self.set_annotations(docs, kb_ids, tensors=tensors)

            if as_example:
                annotated_examples = []
                for ex, doc in zip(examples, docs):
                    ex.doc = doc
                    annotated_examples.append(ex)
                yield from annotated_examples
            else:
                yield from docs

    def predict(self, docs):
        """ Return the KB IDs for each entity in each doc, including NIL if there is no prediction """
        self.require_model()
        self.require_kb()

        entity_count = 0
        final_kb_ids = []
        final_tensors = []

        if not docs:
            return final_kb_ids, final_tensors

        if isinstance(docs, Doc):
            docs = [docs]

        for i, doc in enumerate(docs):
            if len(doc) > 0:
                # Looping through each sentence and each entity
                # This may go wrong if there are entities across sentences - because they might not get a KB ID
                for sent in doc.sents:
                    sent_doc = sent.as_doc()
                    # currently, the context is the same for each entity in a sentence (should be refined)
                    sentence_encoding = self.model([sent_doc])[0]
                    xp = get_array_module(sentence_encoding)
                    sentence_encoding_t = sentence_encoding.T
                    sentence_norm = xp.linalg.norm(sentence_encoding_t)

                    for ent in sent_doc.ents:
                        entity_count += 1

                        to_discard = self.cfg.get("labels_discard", [])
                        if to_discard and ent.label_ in to_discard:
                            # ignoring this entity - setting to NIL
                            final_kb_ids.append(self.NIL)
                            final_tensors.append(sentence_encoding)

                        else:
                            candidates = self.kb.get_candidates(ent.text)
                            if not candidates:
                                # no prediction possible for this entity - setting to NIL
                                final_kb_ids.append(self.NIL)
                                final_tensors.append(sentence_encoding)

                            elif len(candidates) == 1:
                                # shortcut for efficiency reasons: take the 1 candidate

                                # TODO: thresholding
                                final_kb_ids.append(candidates[0].entity_)
                                final_tensors.append(sentence_encoding)

                            else:
                                random.shuffle(candidates)

                                # this will set all prior probabilities to 0 if they should be excluded from the model
                                prior_probs = xp.asarray([c.prior_prob for c in candidates])
                                if not self.cfg.get("incl_prior", True):
                                    prior_probs = xp.asarray([0.0 for c in candidates])
                                scores = prior_probs

                                # add in similarity from the context
                                if self.cfg.get("incl_context", True):
                                    entity_encodings = xp.asarray([c.entity_vector for c in candidates])
                                    entity_norm = xp.linalg.norm(entity_encodings, axis=1)

                                    if len(entity_encodings) != len(prior_probs):
                                        raise RuntimeError(Errors.E147.format(method="predict", msg="vectors not of equal length"))

                                    # cosine similarity
                                    sims = xp.dot(entity_encodings, sentence_encoding_t) / (sentence_norm * entity_norm)
                                    if sims.shape != prior_probs.shape:
                                        raise ValueError(Errors.E161)
                                    scores = prior_probs + sims - (prior_probs*sims)

                                # TODO: thresholding
                                best_index = scores.argmax()
                                best_candidate = candidates[best_index]
                                final_kb_ids.append(best_candidate.entity_)
                                final_tensors.append(sentence_encoding)

        if not (len(final_tensors) == len(final_kb_ids) == entity_count):
            raise RuntimeError(Errors.E147.format(method="predict", msg="result variables not of equal length"))

        return final_kb_ids, final_tensors

    def set_annotations(self, docs, kb_ids, tensors=None):
        count_ents = len([ent for doc in docs for ent in doc.ents])
        if count_ents != len(kb_ids):
            raise ValueError(Errors.E148.format(ents=count_ents, ids=len(kb_ids)))

        i=0
        for doc in docs:
            for ent in doc.ents:
                kb_id = kb_ids[i]
                i += 1
                for token in ent:
                    token.ent_kb_id_ = kb_id

    def to_disk(self, path, exclude=tuple(), **kwargs):
        serialize = {}
        serialize["cfg"] = lambda p: srsly.write_json(p, self.cfg)
        serialize["vocab"] = lambda p: self.vocab.to_disk(p)
        serialize["kb"] = lambda p: self.kb.dump(p)
        if self.model not in (None, True, False):
            serialize["model"] = lambda p: p.open("wb").write(self.model.to_bytes())
        exclude = util.get_serialization_exclude(serialize, exclude, kwargs)
        util.to_disk(path, serialize, exclude)

    def from_disk(self, path, exclude=tuple(), **kwargs):
        def load_model(p):
            if self.model is True:
                self.model = self.Model(**self.cfg)
            try:
                self.model.from_bytes(p.open("rb").read())
            except AttributeError:
                raise ValueError(Errors.E149)

        def load_kb(p):
            kb = KnowledgeBase(vocab=self.vocab, entity_vector_length=self.cfg["entity_width"])
            kb.load_bulk(p)
            self.set_kb(kb)

        deserialize = {}
        deserialize["cfg"] = lambda p: self.cfg.update(_load_cfg(p))
        deserialize["vocab"] = lambda p: self.vocab.from_disk(p)
        deserialize["kb"] = load_kb
        deserialize["model"] = load_model
        exclude = util.get_serialization_exclude(deserialize, exclude, kwargs)
        util.from_disk(path, deserialize, exclude)
        return self

    def rehearse(self, examples, sgd=None, losses=None, **config):
        raise NotImplementedError

    def add_label(self, label):
        raise NotImplementedError


@component("sentencizer", assigns=["token.is_sent_start", "doc.sents"])
class Sentencizer(Pipe):
    """Segment the Doc into sentences using a rule-based strategy.

    DOCS: https://spacy.io/api/sentencizer
    """

    default_punct_chars = ['!', '.', '?', '։', '؟', '۔', '܀', '܁', '܂', '߹',
            '।', '॥', '၊', '။', '።', '፧', '፨', '᙮', '᜵', '᜶', '᠃', '᠉', '᥄',
            '᥅', '᪨', '᪩', '᪪', '᪫', '᭚', '᭛', '᭞', '᭟', '᰻', '᰼', '᱾', '᱿',
            '‼', '‽', '⁇', '⁈', '⁉', '⸮', '⸼', '꓿', '꘎', '꘏', '꛳', '꛷', '꡶',
            '꡷', '꣎', '꣏', '꤯', '꧈', '꧉', '꩝', '꩞', '꩟', '꫰', '꫱', '꯫', '﹒',
            '﹖', '﹗', '！', '．', '？', '𐩖', '𐩗', '𑁇', '𑁈', '𑂾', '𑂿', '𑃀',
            '𑃁', '𑅁', '𑅂', '𑅃', '𑇅', '𑇆', '𑇍', '𑇞', '𑇟', '𑈸', '𑈹', '𑈻', '𑈼',
            '𑊩', '𑑋', '𑑌', '𑗂', '𑗃', '𑗉', '𑗊', '𑗋', '𑗌', '𑗍', '𑗎', '𑗏', '𑗐',
            '𑗑', '𑗒', '𑗓', '𑗔', '𑗕', '𑗖', '𑗗', '𑙁', '𑙂', '𑜼', '𑜽', '𑜾', '𑩂',
            '𑩃', '𑪛', '𑪜', '𑱁', '𑱂', '𖩮', '𖩯', '𖫵', '𖬷', '𖬸', '𖭄', '𛲟', '𝪈']

    def __init__(self, punct_chars=None, **kwargs):
        """Initialize the sentencizer.

        punct_chars (list): Punctuation characters to split on. Will be
            serialized with the nlp object.
        RETURNS (Sentencizer): The sentencizer component.

        DOCS: https://spacy.io/api/sentencizer#init
        """
        if punct_chars:
            self.punct_chars = set(punct_chars)
        else:
            self.punct_chars = set(self.default_punct_chars)

    @classmethod
    def from_nlp(cls, nlp, **cfg):
        return cls(**cfg)

    def __call__(self, example):
        """Apply the sentencizer to a Doc and set Token.is_sent_start.

        example (Doc or Example): The document to process.
        RETURNS (Doc or Example): The processed Doc or Example.

        DOCS: https://spacy.io/api/sentencizer#call
        """
        doc = self._get_doc(example)
        start = 0
        seen_period = False
        for i, token in enumerate(doc):
            is_in_punct_chars = token.text in self.punct_chars
            token.is_sent_start = i == 0
            if seen_period and not token.is_punct and not is_in_punct_chars:
                doc[start].is_sent_start = True
                start = token.i
                seen_period = False
            elif is_in_punct_chars:
                seen_period = True
        if start < len(doc):
            doc[start].is_sent_start = True
        if isinstance(example, Example):
            example.doc = doc
            return example
        return doc

    def pipe(self, stream, batch_size=128, n_threads=-1, as_example=False):
        for batch in util.minibatch(stream, size=batch_size):
            docs = list(batch)
            if as_example:
                docs = [util.eg2doc(doc) for doc in docs]
            tag_ids = self.predict(docs)
            self.set_annotations(docs, tag_ids)
            yield from docs

    def predict(self, docs):
        """Apply the pipeline's model to a batch of docs, without
        modifying them.
        """
        if not any(len(doc) for doc in docs):
            # Handle cases where there are no tokens in any docs.
            guesses = [[] for doc in docs]
            return guesses
        guesses = []
        for doc in docs:
            start = 0
            seen_period = False
            doc_guesses = [False] * len(doc)
            doc_guesses[0] = True
            for i, token in enumerate(doc):
                is_in_punct_chars = token.text in self.punct_chars
                if seen_period and not token.is_punct and not is_in_punct_chars:
                    doc_guesses[start] = True
                    start = token.i
                    seen_period = False
                elif is_in_punct_chars:
                    seen_period = True
            if start < len(doc):
                doc_guesses[start] = True
            guesses.append(doc_guesses)
        return guesses

    def set_annotations(self, docs, batch_tag_ids, tensors=None):
        if isinstance(docs, Doc):
            docs = [docs]
        cdef Doc doc
        cdef int idx = 0
        for i, doc in enumerate(docs):
            doc_tag_ids = batch_tag_ids[i]
            for j, tag_id in enumerate(doc_tag_ids):
                # Don't clobber existing sentence boundaries
                if doc.c[j].sent_start == 0:
                    if tag_id:
                        doc.c[j].sent_start = 1
                    else:
                        doc.c[j].sent_start = -1

    def to_bytes(self, **kwargs):
        """Serialize the sentencizer to a bytestring.

        RETURNS (bytes): The serialized object.

        DOCS: https://spacy.io/api/sentencizer#to_bytes
        """
        return srsly.msgpack_dumps({"punct_chars": list(self.punct_chars)})

    def from_bytes(self, bytes_data, **kwargs):
        """Load the sentencizer from a bytestring.

        bytes_data (bytes): The data to load.
        returns (Sentencizer): The loaded object.

        DOCS: https://spacy.io/api/sentencizer#from_bytes
        """
        cfg = srsly.msgpack_loads(bytes_data)
        self.punct_chars = set(cfg.get("punct_chars", self.default_punct_chars))
        return self

    def to_disk(self, path, exclude=tuple(), **kwargs):
        """Serialize the sentencizer to disk.

        DOCS: https://spacy.io/api/sentencizer#to_disk
        """
        path = util.ensure_path(path)
        path = path.with_suffix(".json")
        srsly.write_json(path, {"punct_chars": list(self.punct_chars)})


    def from_disk(self, path, exclude=tuple(), **kwargs):
        """Load the sentencizer from disk.

        DOCS: https://spacy.io/api/sentencizer#from_disk
        """
        path = util.ensure_path(path)
        path = path.with_suffix(".json")
        cfg = srsly.read_json(path)
        self.punct_chars = set(cfg.get("punct_chars", self.default_punct_chars))
        return self


# Cython classes can't be decorated, so we need to add the factories here
Language.factories["parser"] = lambda nlp, **cfg: DependencyParser.from_nlp(nlp, **cfg)
Language.factories["ner"] = lambda nlp, **cfg: EntityRecognizer.from_nlp(nlp, **cfg)


__all__ = ["Tagger", "DependencyParser", "EntityRecognizer", "Tensorizer", "TextCategorizer", "EntityLinker", "Sentencizer", "SentenceRecognizer"]
