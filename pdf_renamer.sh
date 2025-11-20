#!/bin/bash

###########################################################
# USER SETTINGS
###########################################################
WATCHDIR="/Users/rnj/DWork/sandbox"
FINALDIR="/Users/rnj/Library/CloudStorage/Dropbox/Reprint"

PDFTOTEXT="/usr/local/bin/pdftotext"
JQ="/opt/anaconda3/bin/jq"
CURL="/opt/anaconda3/bin/curl"

###########################################################
# FIND MOST RECENT PDF IN WATCH DIRECTORY
###########################################################
PDF=$(ls -t "$WATCHDIR"/*.pdf 2>/dev/null | head -n 1)
[[ -z "$PDF" ]] && exit 0

DIR=$(dirname "$PDF")
BASE=$(basename "$PDF")

if [[ "$PDF" != *.pdf && "$PDF" != *.PDF ]]; then
    exit 0
fi

###########################################################
# EXTRACT TEXT
###########################################################
PDF_TEXT=$("$PDFTOTEXT" "$PDF" - 2>/dev/null)

###########################################################
# SYSTEM & USER MESSAGES (Unicode-safe, jq-safe)
###########################################################
SYSTEM_MSG="Extract academic article metadata. Return ONLY raw JSON. No markdown. No code fences.

Required keys:
- first_author_last
- all_authors_last
- authors_full
- year
- title
- journal
- volume
- issue
- pages
- doi

Also return a key called \"ris_authors\":
This must be a list of RIS-formatted author strings, each like:
\"Lastname, First MiddleInitials\".

Rules:
- Extract names ONLY from the PDF.
- Reconstruct names even if split across lines.
- Remove academic degrees (PhD, MD, ScD, etc.).
- Preserve diacritics (Ø, Ü, ñ, é, ç, å).
- Preserve hyphens in surnames (e.g., Pascual-Leone).
"

USER_MSG="Extract metadata and also return a fully formatted list called \"ris_authors\". 
Each element must be a valid RIS author string formatted as:
\"Lastname, First Middle\".

Do NOT include academic degrees.
Do NOT guess names.
Do NOT output markdown.

TEXT FROM PDF:
$PDF_TEXT
"

###########################################################
# BUILD JSON CLEANLY (NO ESCAPING REQUIREMENTS)
###########################################################
JSON=$("$JQ" -n \
  --arg sys "$SYSTEM_MSG" \
  --arg usr "$USER_MSG" \
  '
{
  "model": "gpt-4o-mini",
  "temperature": 0,
  "messages": [
    { "role": "system", "content": $sys },
    { "role": "user",   "content": $usr }
  ]
}
'
)

###########################################################
# CALL OPENAI API
###########################################################
RESPONSE=$("$CURL" -s https://api.openai.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -d "$JSON")

echo "$RESPONSE" > /tmp/gpt_response.json

###########################################################
# CLEAN ANY CODE FENCES (GPT should not produce these)
###########################################################
CLEAN=$(echo "$RESPONSE" | sed 's/```json//g' | sed 's/```//g')

META='.choices[0].message.content | fromjson |'

###########################################################
# PARSE METADATA
###########################################################
AUTHOR=$(echo "$CLEAN"     | $JQ -r "$META .first_author_last")
AUTH_LAST_LIST=$(echo "$CLEAN" | $JQ -r "$META .all_authors_last")
AUTHORS_FULL=$(echo "$CLEAN"| $JQ -r "$META .authors_full")

YEAR=$(echo "$CLEAN"   | $JQ -r "$META .year")
TITLE=$(echo "$CLEAN"  | $JQ -r "$META .title")
FULL_TITLE="$TITLE"
JOURNAL=$(echo "$CLEAN"| $JQ -r "$META .journal")
VOLUME=$(echo "$CLEAN" | $JQ -r "$META .volume")
ISSUE=$(echo "$CLEAN"  | $JQ -r "$META .issue")
PAGES=$(echo "$CLEAN"  | $JQ -r "$META .pages")
DOI=$(echo "$CLEAN"    | $JQ -r "$META .doi")

###########################################################
# FALLBACKS
###########################################################
[[ "$YEAR" == "null" || -z "$YEAR" ]] && YEAR="XXXX"
[[ "$AUTHOR" == "null" ]] && AUTHOR=""
[[ "$TITLE" == "null" ]] && TITLE=""
[[ "$JOURNAL" == "null" ]] && JOURNAL=""
[[ "$VOLUME" == "null" ]] && VOLUME=""
[[ "$ISSUE" == "null" ]] && ISSUE=""
[[ "$PAGES" == "null" ]] && PAGES=""
[[ "$DOI" == "null" ]] && DOI=""

# If no usable metadata, quit
if [[ -z "$AUTHOR" && "$YEAR" == "XXXX" && -z "$TITLE" ]]; then
    exit 0
fi

###########################################################
# FILENAME AUTHOR BLOCK
###########################################################
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

###########################################################
# CLEAN TITLE FOR FILENAME
###########################################################
TITLE_CLEAN=$(echo "$TITLE" | tr ' ' '-' | tr -cd '[:alnum:]\-_' | cut -c1-50)

###########################################################
# BUILD NEW PDF NAME
###########################################################
NEWNAME="${AUTHOR_BLOCK}_${YEAR}_${TITLE_CLEAN}.pdf"
NEWPATH="$DIR/$NEWNAME"

# Avoid collisions
if [[ -e "$NEWPATH" ]]; then
    NEWPATH="$DIR/${AUTHOR_BLOCK}_${YEAR}_${TITLE_CLEAN}_$(date +%s).pdf"
fi

###########################################################
# RENAME THEN MOVE TO FINAL DIRECTORY
###########################################################
/bin/mv "$PDF" "$NEWPATH"

mkdir -p "$FINALDIR"
/bin/mv "$NEWPATH" "$FINALDIR/"

###########################################################
# GENERATE RIS FILE
###########################################################
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

# DOI URL
if [[ -n "$DOI" && "$DOI" != "null" ]]; then
    echo "UR  - https://doi.org/$DOI" >> "$RISFILE"
fi

###########################################################
# RIS AUTHORS — GPT FORMATTED (Fix #3)
###########################################################
RIS_AUTHORS=$(echo "$CLEAN" | $JQ -r "$META .ris_authors")

if [[ "$RIS_AUTHORS" != "null" ]]; then
    echo "$RIS_AUTHORS" | $JQ -r '.[]' | while read -r author; do
        echo "AU  - $author" >> "$RISFILE"
    done
fi

echo "ER  -" >> "$RISFILE"

# DONE