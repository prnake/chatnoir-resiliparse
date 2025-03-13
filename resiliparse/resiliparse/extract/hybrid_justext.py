from resiliparse.extract.html2text import extract_plain_text, extract_paragraphs
from justext import get_stoplist
import re

MULTIPLE_WHITESPACE_PATTERN = re.compile(r"\s+", re.UNICODE)

def _replace_whitespace(match):
    """Normalize all spacing characters that aren't a newline to a space."""
    text = match.group()
    return "\n" if "\n" in text or "\r" in text else " "

def normalize_whitespace(text):
    """
    Translates multiple whitespace into single space character.
    If there is at least one new line character chunk is replaced
    by single LF (Unix new line) character.
    """
    return MULTIPLE_WHITESPACE_PATTERN.sub(_replace_whitespace, text)

def is_blank(string):
    """
    Returns `True` if string contains only white-space characters
    or is empty. Otherwise `False` is returned.
    """
    return not string or string.isspace()

HEADINGS_PATTERN = re.compile(r"\bh\d\b")

class Paragraph(object):
    """Object representing one block of text in HTML."""
    def __init__(self, text_nodes, dom_path, chars_count_in_links, tags_count, head_tag_count):
        self.text_nodes = text_nodes
        self.dom_path = dom_path
        self.chars_count_in_links = chars_count_in_links
        self.tags_count = tags_count
        self.head_tag_count = head_tag_count
        self.class_type = ""  # short | neargood | good | bad
        self.text = self.get_text()
        self.is_heading = head_tag_count > 0
        self.words_count = len(self.text.split())
        self.links_density = self.get_links_density()

    @property
    def is_boilerplate(self):
        return self.class_type != "good"

    def get_text(self):
        text = "".join([node for node in self.text_nodes if (not is_blank(node)) or node == " "])
        return normalize_whitespace(text.strip())

    def __len__(self):
        return len(self.text)

    def stopwords_count(self, stopwords):
        return sum(word.lower() in stopwords for word in self.text.split())

    def stopwords_density(self, stopwords):
        if self.words_count == 0:
            return 0

        return self.stopwords_count(stopwords) / self.words_count

    def get_links_density(self):
        text_length = len(self.text)
        if text_length == 0:
            return 0

        return self.chars_count_in_links / text_length

"""
Copyright (c) 2011 Jan Pomikalek

This software is licensed as described in the file LICENSE.rst.
"""
try:
    from functools import lru_cache
except ImportError:
    from backports.functools_lru_cache import lru_cache

DEFAULT_ENCODING = 'utf8'
DEFAULT_ENC_ERRORS = 'replace'
MAX_LINK_DENSITY_DEFAULT = 0.2
LENGTH_LOW_DEFAULT = 70
LENGTH_HIGH_DEFAULT = 200
STOPWORDS_LOW_DEFAULT = 0.30
STOPWORDS_HIGH_DEFAULT = 0.32
NO_HEADINGS_DEFAULT = False
# Short and near-good headings within MAX_HEADING_DISTANCE characters before
# a good paragraph are classified as good unless --no-headings is specified.
MAX_HEADING_DISTANCE_DEFAULT = 200
MAX_PARAGRAPH_LENGTH_DEFAULT = 100000
GOOD_OR_BAD = {'good', 'bad'}
GOOD_BAD_NEARGOOD = {'good', 'bad', 'neargood'}

@lru_cache(maxsize=128)  # 100 stoplists
def define_stoplist(stoplist):
    "Lower-case all words in stoplist and create frozen set."
    stoplist = frozenset(w.lower() for w in stoplist)
    return stoplist


def classify_paragraphs(paragraphs, stoplist, length_low=LENGTH_LOW_DEFAULT,
        length_high=LENGTH_HIGH_DEFAULT, stopwords_low=STOPWORDS_LOW_DEFAULT,
        stopwords_high=STOPWORDS_HIGH_DEFAULT, max_link_density=MAX_LINK_DENSITY_DEFAULT,
        no_headings=NO_HEADINGS_DEFAULT):
    "Context-free paragraph classification."

    # stoplist = define_stoplist(stoplist)
    for paragraph in paragraphs:
        length = len(paragraph)
        stopword_density = paragraph.stopwords_density(stoplist)
        link_density = paragraph.links_density
        paragraph.heading = bool(not no_headings and paragraph.is_heading)

        if link_density > max_link_density:
            paragraph.cf_class = 'bad'
        elif ('\xa9' in paragraph.text) or ('&copy' in paragraph.text):
            paragraph.cf_class = 'bad'
        # already removed in dom clean
        # elif paragraph.select_tag_count > 0:
        #     paragraph.cf_class = 'bad'
        elif length < length_low:
            if paragraph.chars_count_in_links > 0:
                paragraph.cf_class = 'bad'
            else:
                paragraph.cf_class = 'short'
        elif stopword_density >= stopwords_high:
            if length > length_high:
                paragraph.cf_class = 'good'
            else:
                paragraph.cf_class = 'neargood'
        elif stopword_density >= stopwords_low:
            paragraph.cf_class = 'neargood'
        else:
            paragraph.cf_class = 'bad'


def revise_paragraph_classification_fast(paragraphs, max_heading_distance=MAX_HEADING_DISTANCE_DEFAULT):
    """
    Optimized context-sensitive paragraph classification. Assumes that classify_pragraphs has already been called.
    Complexity is O(n), avoiding repeated traversals by pre-computing neighbor information.
    """
    n = len(paragraphs)
    
    # Attention: This is a fix for the bug in the original code.
    # Copy the context free class to the class_style
    # This handles the headings as described in the
    # documentation
    for paragraph in paragraphs:
        paragraph.class_type = paragraph.cf_class
    
    # Pre-compute the position of the next good/bad element
    next_good_or_bad = [n] * n  # Default to end of paragraph list
    next_good_or_bad_or_neargood = [n] * n
    
    # Pre-compute the position of the previous good/bad element
    prev_good_or_bad = [-1] * n  # Default to beginning of paragraph list
    prev_good_or_bad_or_neargood = [-1] * n
    
    # Step 1: Process good headings
    # Pre-compute text length for each paragraph
    text_lengths = [len(p.text) for p in paragraphs]
    
    # Pre-compute the position of good paragraphs after each position
    next_good_pos = [n] * n
    for i in range(n-1, -1, -1):
        if paragraphs[i].class_type == 'good':
            next_good_pos[i] = i
        elif i < n-1:
            next_good_pos[i] = next_good_pos[i+1]
    
    for i, paragraph in enumerate(paragraphs):
        if not (paragraph.heading and paragraph.class_type == 'short'):
            continue
        
        # Use pre-computed next_good_pos to quickly find the next good paragraph
        j = i + 1
        if j < n and next_good_pos[j] < n:
            # Calculate distance
            distance = sum(text_lengths[k] for k in range(i+1, next_good_pos[j]))
            if distance <= max_heading_distance:
                paragraph.class_type = 'neargood'
    
    # Fill previous element indices from back to front
    for i in range(n-2, -1, -1):
        # good or bad
        if paragraphs[i+1].class_type in GOOD_OR_BAD:
            prev_good_or_bad[i] = i+1
            prev_good_or_bad_or_neargood[i] = i+1
        else:
            prev_good_or_bad[i] = prev_good_or_bad[i+1]
            
        if paragraphs[i+1].class_type in GOOD_BAD_NEARGOOD:
            prev_good_or_bad_or_neargood[i] = i+1
        else:
            prev_good_or_bad_or_neargood[i] = prev_good_or_bad_or_neargood[i+1]
    
    # Fill next element indices from front to back
    for i in range(1, n):
        # good or bad
        if paragraphs[i-1].class_type in GOOD_OR_BAD:
            next_good_or_bad[i] = i-1
            next_good_or_bad_or_neargood[i] = i-1
        else:
            next_good_or_bad[i] = next_good_or_bad[i-1]
            
        if paragraphs[i-1].class_type in GOOD_BAD_NEARGOOD:
            next_good_or_bad_or_neargood[i] = i-1
        else:
            next_good_or_bad_or_neargood[i] = next_good_or_bad_or_neargood[i-1]

    # Step 2: Classify short paragraphs
    new_classes = {}
    for i, paragraph in enumerate(paragraphs):
        if paragraph.class_type != 'short':
            continue
        
        # Use pre-computed indices to get neighbor types
        prev_idx = next_good_or_bad[i]
        next_idx = prev_good_or_bad[i]
        
        prev_neighbour = paragraphs[prev_idx].class_type if prev_idx >= 0 and prev_idx < n else 'bad'
        next_neighbour = paragraphs[next_idx].class_type if next_idx >= 0 and next_idx < n else 'bad'
        
        if prev_neighbour == 'good' and next_neighbour == 'good':
            new_classes[i] = 'good'
        elif prev_neighbour == 'bad' and next_neighbour == 'bad':
            new_classes[i] = 'bad'
        else:
            # Check if there are neargood neighbors
            prev_neargood_idx = next_good_or_bad_or_neargood[i]
            next_neargood_idx = prev_good_or_bad_or_neargood[i]
            
            prev_with_neargood = paragraphs[prev_neargood_idx].class_type if prev_neargood_idx >= 0 and prev_neargood_idx < n else 'bad'
            next_with_neargood = paragraphs[next_neargood_idx].class_type if next_neargood_idx >= 0 and next_neargood_idx < n else 'bad'
            
            if (prev_neighbour == 'bad' and prev_with_neargood == 'neargood') or \
               (next_neighbour == 'bad' and next_with_neargood == 'neargood'):
                new_classes[i] = 'good'
            else:
                new_classes[i] = 'bad'
    
    # Apply new classifications
    for i, c in new_classes.items():
        paragraphs[i].class_type = c
    
    # Note: Interesting that this is not needed.
    # Update indices again, as some paragraphs have changed
    """
    for i in range(n-2, -1, -1):
        if paragraphs[i+1].class_type in GOOD_OR_BAD:
            prev_good_or_bad[i] = i+1
        else:
            prev_good_or_bad[i] = prev_good_or_bad[i+1]
    
    for i in range(1, n):
        if paragraphs[i-1].class_type in GOOD_OR_BAD:
            next_good_or_bad[i] = i-1
        else:
            next_good_or_bad[i] = next_good_or_bad[i-1]
    """
            

    # Step 3: Revise neargood paragraphs
    for i, paragraph in enumerate(paragraphs):
        if paragraph.class_type != 'neargood':
            continue
        
        prev_idx = next_good_or_bad[i]
        next_idx = prev_good_or_bad[i]
        
        prev_neighbour = paragraphs[prev_idx].class_type if prev_idx >= 0 and prev_idx < n else 'bad'
        next_neighbour = paragraphs[next_idx].class_type if next_idx >= 0 and next_idx < n else 'bad'
        
        if (prev_neighbour, next_neighbour) == ('bad', 'bad'):
            paragraph.class_type = 'bad'
        else:
            paragraph.class_type = 'good'
    
    # Step 4: More good headings
    # Pre-compute the position of the first good paragraph after each position
    next_good_pos = [n] * n
    for i in range(n-1, -1, -1):
        if paragraphs[i].class_type == 'good':
            next_good_pos[i] = i
        elif i < n-1:
            next_good_pos[i] = next_good_pos[i+1]
    
    for i, paragraph in enumerate(paragraphs):
        if not (paragraph.heading and paragraph.class_type == 'bad' and paragraph.cf_class != 'bad'):
            continue

        # Use pre-computed next_good_pos to quickly find the next good paragraph
        j = i + 1
        if j < n and next_good_pos[j] < n:
            # Calculate distance
            distance = sum(text_lengths[k] for k in range(i+1, next_good_pos[j]))
            if distance <= max_heading_distance:
                paragraph.class_type = 'good'



def custom_justext(paragraphs, length_low=LENGTH_LOW_DEFAULT,
        length_high=LENGTH_HIGH_DEFAULT, stopwords_low=STOPWORDS_LOW_DEFAULT,
        stopwords_high=STOPWORDS_HIGH_DEFAULT, max_link_density=MAX_LINK_DENSITY_DEFAULT,
        max_heading_distance=MAX_HEADING_DISTANCE_DEFAULT, no_headings=NO_HEADINGS_DEFAULT,
        encoding=None, default_encoding=DEFAULT_ENCODING,
        enc_errors=DEFAULT_ENC_ERRORS, max_paragraph_length=MAX_PARAGRAPH_LENGTH_DEFAULT):

    stoplist = get_stoplist("English")
    classify_paragraphs(paragraphs, stoplist, length_low, length_high,
        stopwords_low, stopwords_high, max_link_density, no_headings)
    
    revise_paragraph_classification_fast(paragraphs, max_heading_distance)

    return paragraphs

def hybrid_justext(html):
    paragraphs = []
    for paragraph in extract_paragraphs(html):
        p = Paragraph(**paragraph)
        if p.text.strip():
            paragraphs.append(p)
    paragraphs = custom_justext(paragraphs)
    return paragraphs