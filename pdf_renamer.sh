#!/bin/bash

###############################################
# USER SETTINGS — EDIT THESE IF NEEDED
###############################################
WATCHDIR="/Users/rnj/DWork/sandbox"
FINALDIR="/Users/rnj/Library/CloudStorage/Dropbox/Reprint"

PDFTOTEXT="/usr/local/bin/pdftotext"
JQ="/opt/anaconda3/bin/jq"
CURL="/opt/anaconda3/bin/curl"

###############################################
# SELECT MOST RECENT PDF (WatchPaths does not pass args)
###############################################
PDF=$(ls -t "$WATCHDIR"/*.pdf 2>/dev/null | head -n 1)

[[ -z "$PDF" ]] && exit 0

DIR=$(dirname "$PDF")
BASE=$(basename "$PDF")

if [[ "$PDF" != *.pdf && "$PDF" != *.PDF ]]; then
    exit 0
fi

###############################################
# EXTRACT TEXT FROM PDF
###############################################
PDF_TEXT=$("$PDFTOTEXT" "$PDF" - 2>/dev/null)

###############################################
# BUILD GPT REQUEST (Fix #3 — add ris_authors)
###############################################
JSON=$("$JQ" -n --arg text "$PDF_TEXT" '
{
  "model": "gpt-4o-mini",
  "temperature": 0,
  "messages": [
    {
      "role": "system",
      "content": "Extract academic article metadata. Return ONLY raw JSON. No markdown. No code fences. Required keys: first_author_last, all_authors_last, authors_full, year, title, journal, volume, issue, pages, doi. Also return ris_authors: a list of fully formatted RIS author strings, each of the form \"Lastname, First MiddleInitials\". Reconstruct names even if split across lines. Remove academic degrees (PhD, MD, etc.). Preserve diacritics (Ø, ü, ñ). Extract only names that appear in the PDF."
    },
    {
      "role": "user",
      "content": ("Extract metadata and also return a fully formatted list called ris_authors. Each element must be a valid RIS author string ('Lastname, First Middle'). Do not include degrees. Do not include markdown. Output only JSON.\n\nTEXT:\n" + $text)
    }
  ]
}
')

###############################################
# CALL OPENAI API
###############################################
RESPONSE=$("$CURL" -s https://api.openai.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -d "$JSON")

echo "$RESPONSE" > /tmp/gpt_response.json

###############################################
# CLEAN CODE FENCES IF GPT DISOBEYS
###############################################
CLEAN=$(echo "$RESPONSE" \
    | sed 's/```json//g' \
    | sed 's/```//g')

###############################################
# PARSE METADATA
###############################################
META='.choices[0].message.content | fromjson |'

AUTHOR=$(echo "$CLEAN" | $JQ -r "$META .first_author_last")
AUTH_LAST_LIST=$(echo "$CLEAN" | $JQ -r "$META .all_authors_last")
AUTHORS_FULL=$(echo "$CLEAN" | $JQ -r "$META .authors_full")

YEAR=$(echo "$CLEAN"   | $JQ -r "$META .year")
TITLE=$(echo "$CLEAN"  | $JQ -r "$META .title")
FULL_TITLE="$TITLE"
JOURNAL=$(echo "$CLEAN"| $JQ -r "$META .journal")
VOLUME=$(echo "$CLEAN" | $JQ -r "$META .volume")
ISSUE=$(echo "$CLEAN"  | $JQ -r "$META .issue")
PAGES=$(echo "$CLEAN"  | $JQ -r "$META .pages")
DOI=$(echo "$CLEAN"    | $JQ -r "$META .doi")

###############################################
# FALLBACKS
###############################################
[[ "$YEAR" == "null" || -z "$YEAR" ]] && YEAR="XXXX"
[[ "$AUTHOR" == "null" ]] && AUTHOR=""
[[ "$TITLE" == "null" ]] && TITLE=""
[[ "$JOURNAL" == "null" ]] && JOURNAL=""
[[ "$VOLUME" == "null" ]] && VOLUME=""
[[ "$ISSUE" == "null" ]] && ISSUE=""
[[ "$PAGES" == "null" ]] && PAGES=""
[[ "$DOI" == "null" ]] && DOI=""

# If absolutely nothing useful was extracted, exit
if [[ -z "$AUTHOR" && "$YEAR" == "XXXX" && -z "$TITLE" ]]; then
    exit 0
fi

###############################################
# BUILD AUTHOR BLOCK FOR FILENAME
###############################################
NUMAUTH=$(echo "$AUTH_LAST_LIST" | $JQ 'length')

if [[ "$NUMAUTH" -eq 1 ]]; then
    AUTHOR_BLOCK=$(echo "$AUTH_LAST_LIST" | $JQ -r '.[0]')
elif [[ "$NUMAUTH" -eq 2 ]]; then
    A1=$(echo "$AUTH_LAST_LIST" | $JQ -r '.[0]')
    A2=$(echo "$AUTH_LAST_LIST" | $JQ -r '.[1]')
    AUTHOR_BLOCK="${A1}-${A2}"
else
    AUTHOR_BLOCK=$(echo "$AUTH_LAST_LIST" | $JQ -r '.[0]')
fi

###############################################
# CLEAN TITLE FOR FILENAME
###############################################
TITLE_CLEAN=$(echo "$TITLE" | tr ' ' '-' | tr -cd '[:alnum:]\-_' | cut -c1-50)

###############################################
# BUILD NEW PDF NAME
###############################################
NEWNAME="${AUTHOR_BLOCK}_${YEAR}_${TITLE_CLEAN}.pdf"
NEWPATH="$DIR/$NEWNAME"

if [[ -e "$NEWPATH" ]]; then
    NEWPATH="$DIR/${AUTHOR_BLOCK}_${YEAR}_${TITLE_CLEAN}_$(date +%s).pdf"
fi

###############################################
# RENAME → MOVE TO FINALDIR
###############################################
/bin/mv "$PDF" "$NEWPATH"

mkdir -p "$FINALDIR"
/bin/mv "$NEWPATH" "$FINALDIR/"

###############################################
# GENERATE RIS FILE in WATCHDIR
###############################################
RISFILE="${WATCHDIR}/${AUTHOR_BLOCK}_${YEAR}_${TITLE_CLEAN}.ris"

cat <<EOF > "$RISFILE"
TY  - JOUR
TI  - $FULL_TITLE
T1  - $FULL_TITLE
JF  - $JOURNAL
JO  - $JOURNAL
PY  - $YEAR
VL  - $VOLUME
IS  - $ISSUE
SP  - $PAGES
DO  - $DOI
EOF

# Add DOI URL if available
if [[ -n "$DOI" && "$DOI" != "null" ]]; then
    echo "UR  - https://doi.org/$DOI" >> "$RISFILE"
fi

###############################################
# ADD GPT-FORMATTED RIS AUTHORS (Fix #3)
###############################################
RIS_AUTHORS=$(echo "$CLEAN" | $JQ -r "$META .ris_authors")

if [[ "$RIS_AUTHORS" != "null" ]]; then
    echo "$RIS_AUTHORS" | $JQ -r '.[]' | while read -r author; do
        echo "AU  - $author" >> "$RISFILE"
    done
fi

echo "ER  -" >> "$RISFILE"

# END OF SCRIPT