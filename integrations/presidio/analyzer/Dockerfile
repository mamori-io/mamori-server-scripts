FROM ghcr.io/data-privacy-stack/presidio-analyzer:latest

COPY default.yaml /app/presidio_analyzer/conf/default.yaml
COPY default_analyzer.yaml /app/presidio_analyzer/conf/default_analyzer.yaml
COPY default_recognizers.yaml /app/presidio_analyzer/conf/default_recognizers.yaml
COPY thai_person_recognizer.py /app/presidio_analyzer/predefined_recognizers/country_specific/thai/thai_person_recognizer.py
COPY setup_thai.py /tmp/setup_thai.py
COPY patch_imports.py /tmp/patch_imports.py

USER root
RUN python /tmp/patch_imports.py \
    && pip install --no-cache-dir python-crfsuite pythainlp
USER presidio
RUN python /tmp/setup_thai.py
