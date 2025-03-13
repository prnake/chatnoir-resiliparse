from resiliparse.extract.justext import justext

class Paragraph(object):
    def __init__(self, text, dom_path, chars_count_in_links, tags_count, head_tag_count, words_count, links_density, is_heading, cf_class, class_type, stopwords_count, stopword_density):
        self.text = text
        self.dom_path = dom_path
        self.chars_count_in_links = chars_count_in_links
        self.tags_count = tags_count
        self.head_tag_count = head_tag_count
        self.words_count = words_count
        self.links_density = links_density
        self.stopword_density = stopword_density
        self.cf_class = cf_class
        self.class_type = class_type
        self.stopwords_count = stopwords_count
        self.heading = self.is_heading = is_heading
        self.is_boilerplate = self.class_type != "good"

    def __len__(self):
        return len(self.text)

def lexbor_justext(html, stoplist=None, language="English", length_low=70, length_high=200, stopwords_low=0.30,
                            stopwords_high=0.32, max_link_density=0.2, max_heading_distance=200, no_headings=False):
    paragraphs = []
    for paragraph in justext(html, stoplist=stoplist, language=language, length_low=length_low, length_high=length_high, stopwords_low=stopwords_low,
                                stopwords_high=stopwords_high, max_link_density=max_link_density, max_heading_distance=max_heading_distance, no_headings=no_headings):
        p = Paragraph(**paragraph)
        paragraphs.append(p)
    return paragraphs