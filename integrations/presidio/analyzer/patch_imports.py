from pathlib import Path

thai_init = Path("/app/presidio_analyzer/predefined_recognizers/country_specific/thai/__init__.py")
text = thai_init.read_text()
if "ThaiPersonRecognizer" not in text:
    text = text.replace(
        "from .th_tnin_recognizer import ThTninRecognizer",
        "from .th_tnin_recognizer import ThTninRecognizer\n"
        "from .thai_person_recognizer import ThaiPersonRecognizer",
    )
    text = text.replace(
        '"ThTninRecognizer",',
        '"ThTninRecognizer",\n    "ThaiPersonRecognizer",',
    )
    thai_init.write_text(text)

pkg_init = Path("/app/presidio_analyzer/predefined_recognizers/__init__.py")
text = pkg_init.read_text()
if "ThaiPersonRecognizer" not in text:
    text = text.replace(
        "from .country_specific.thai.th_tnin_recognizer import ThTninRecognizer",
        "from .country_specific.thai.th_tnin_recognizer import ThTninRecognizer\n"
        "from .country_specific.thai.thai_person_recognizer import ThaiPersonRecognizer",
    )
    pkg_init.write_text(text)

print(thai_init.read_text())
print("---")
for line in pkg_init.read_text().splitlines():
    if "Thai" in line or "ThTnin" in line:
        print(line)
