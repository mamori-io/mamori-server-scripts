from pathlib import Path

import spacy
from pythainlp.tag.thainer import ThaiNameTagger

dest = Path("/home/presidio/models/th_blank")
dest.parent.mkdir(parents=True, exist_ok=True)
nlp = spacy.blank("th")
nlp.to_disk(dest)
print("wrote", dest, "exists", dest.is_dir())
tagger = ThaiNameTagger()
print(tagger.get_ner("นายสมชาย ใจดี"))
