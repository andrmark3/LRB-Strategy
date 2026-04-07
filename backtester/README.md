# Backtester

Place `LRB_V2.html` in this folder.

The HTML backtester is the browser UI for the strategy — same logic as the Python engine.
Open in any browser. No server needed. Just drag and drop your CSV file.

## Getting LRB_V2.html
Download `LRB_V2.html` from the Claude conversation outputs and save it here.

## Relationship to engine/
The JS in `LRB_V2.html` implements the same logic as the Python engine.
- When changing a filter in `engine/filters.py` → update the matching JS in the HTML
- Always test in Python first (fast CLI), then update HTML to match
