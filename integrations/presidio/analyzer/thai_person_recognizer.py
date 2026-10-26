"""Thai PERSON recognizer using PyThaiNLP's CRF name tagger."""

from __future__ import annotations

import logging
import re
from typing import List, Optional

from presidio_analyzer import EntityRecognizer, RecognizerResult

logger = logging.getLogger("presidio-analyzer")

THAI_CHAR = re.compile(r"[\u0E00-\u0E7F]")
THAI_ONLY = re.compile(r"^[\u0E00-\u0E7F\s.\-·]+$")
PERSON_TAGS = {"PERSON", "PER", "B-PERSON", "I-PERSON", "B-PER", "I-PER"}


class ThaiPersonRecognizer(EntityRecognizer):
    """Detect Thai-script person names via PyThaiNLP ThaiNameTagger."""

    def __init__(
        self,
        supported_language: str = "th",
        name: Optional[str] = None,
        **kwargs,
    ):
        kwargs.pop("supported_entity", None)
        kwargs.pop("supported_entities", None)
        kwargs.pop("context", None)
        self._tagger = None
        super().__init__(
            supported_entities=["PERSON"],
            supported_language=supported_language,
            name=name or "ThaiPersonRecognizer",
        )

    def load(self) -> None:
        if self._tagger is not None:
            return
        from pythainlp.tag.thainer import ThaiNameTagger

        self._tagger = ThaiNameTagger()
        logger.info("Loaded PyThaiNLP ThaiNameTagger for Thai PERSON NER")

    def analyze(self, text: str, entities: List[str], nlp_artifacts=None):
        if not text or (entities and "PERSON" not in entities):
            return []
        if not THAI_CHAR.search(text):
            return []
        try:
            self.load()
        except Exception as exc:
            logger.warning("Thai PERSON NER unavailable: %s", exc)
            return self._isolated_name_fallback(text)

        results = self._from_tagger(text)
        if not results:
            results = self._isolated_name_fallback(text)
        return results

    def _from_tagger(self, text: str) -> List[RecognizerResult]:
        tagged = self._tagger.get_ner(text)
        chunks: List[str] = []
        current: List[str] = []
        for item in tagged or []:
            if isinstance(item, (list, tuple)) and len(item) >= 2:
                word, tag = item[0], str(item[-1])
            else:
                continue
            norm = tag.upper().split("-")[-1]
            if tag.upper() in PERSON_TAGS or norm in {"PERSON", "PER"}:
                if tag.upper().startswith("B-") and current:
                    chunks.append("".join(current))
                    current = [word]
                else:
                    current.append(word)
            elif current:
                chunks.append("".join(current))
                current = []
        if current:
            chunks.append("".join(current))

        results: List[RecognizerResult] = []
        used = set()
        for chunk in chunks:
            chunk = chunk.strip()
            if len(chunk) < 2:
                continue
            start = text.find(chunk)
            while start != -1 and start in used:
                start = text.find(chunk, start + 1)
            if start == -1:
                continue
            end = start + len(chunk)
            used.add(start)
            results.append(
                RecognizerResult(
                    entity_type="PERSON",
                    start=start,
                    end=end,
                    score=0.75,
                )
            )
        return results

    def _isolated_name_fallback(self, text: str) -> List[RecognizerResult]:
        stripped = text.strip()
        compact = re.sub(r"\s+", "", stripped)
        if not stripped or not THAI_ONLY.match(stripped):
            return []
        if not (2 <= len(compact) <= 30):
            return []
        start = text.find(stripped)
        if start < 0:
            return []
        return [
            RecognizerResult(
                entity_type="PERSON",
                start=start,
                end=start + len(stripped),
                score=0.6,
            )
        ]
