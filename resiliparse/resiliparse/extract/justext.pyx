# Copyright 2025 Papersnake
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# distutils: language = c++

from cython.operator cimport dereference as deref, preincrement as preinc, predecrement as predec
from libcpp.set cimport set as stl_set
from libcpp.string cimport string, npos as strnpos
from libcpp.vector cimport vector

from resiliparse_common.string_util cimport lstrip_str, rstrip_str, strip_str, strip_sv, normalize_whitespace
from resiliparse_inc.cctype cimport isspace, tolower
from resiliparse.parse.html cimport *
from resiliparse_inc.lexbor cimport *

__all__ = ['justext']

# 定义分类常量
cdef int CLASS_SHORT = 0
cdef int CLASS_NEARGOOD = 1
cdef int CLASS_GOOD = 2
cdef int CLASS_BAD = 3
cdef list CLASS_NAMES = ['short', 'neargood', 'good', 'bad']

# 定义 Paragraph 结构体
cdef struct Paragraph:
    vector[string] text_nodes       # 文本节点列表
    string dom_path                 # DOM 路径
    size_t chars_count_in_links     # 链接中的字符数
    size_t tags_count               # 标签计数
    size_t head_tag_count           # 标题标签计数
    string text                     # 计算后的文本
    size_t words_count              # 文本中的单词数
    size_t text_py_length           # UTF-8下的文本数
    size_t text_c_length            # std::string下的文本数
    size_t stopwords_count          # 停用词个数
    double links_density            # 链接字符占总文本长度的比例
    double stopword_density         # 停用词占总文本长度的比例
    bint is_heading                 # 是否为标题
    int cf_class                    # 无上下文分类（0=short, 1=neargood, 2=good, 3=bad）
    int class_type                  # 修订后的最终分类

# 定义常用标签集合
cdef stl_set[string] HEAD_STR_TAGS = {b'h1', b'h2', b'h3', b'h4', b'h5', b'h6'}

# 定义段落相关的常量
cdef stl_set[lxb_tag_id_t] PARAGRAPH_TAGS = {
    LXB_TAG_BODY, LXB_TAG_BLOCKQUOTE, LXB_TAG_CAPTION, LXB_TAG_CENTER, LXB_TAG_COL,
    LXB_TAG_COLGROUP, LXB_TAG_DD, LXB_TAG_DIV, LXB_TAG_DL, LXB_TAG_DT,
    LXB_TAG_FIELDSET, LXB_TAG_FORM, LXB_TAG_LEGEND, LXB_TAG_OPTGROUP, LXB_TAG_OPTION,
    LXB_TAG_P, LXB_TAG_PRE, LXB_TAG_TABLE, LXB_TAG_TD, LXB_TAG_TEXTAREA,
    LXB_TAG_TFOOT, LXB_TAG_TH, LXB_TAG_THEAD, LXB_TAG_TR, LXB_TAG_UL, LXB_TAG_LI,
    LXB_TAG_H1, LXB_TAG_H2, LXB_TAG_H3, LXB_TAG_H4, LXB_TAG_H5, LXB_TAG_H6
}

# 检查字符串是否为空或只包含空白字符
cdef bint is_blank(const string& s) noexcept nogil:
    """
    检查字符串是否为空或只包含空白字符
    
    参数:
        s: 要检查的字符串
        
    返回:
        bint: 如果字符串为空或只包含空白字符则返回True，否则返回False
    """
    if s.empty():
        return True

    for i in range(s.size()):
        if not isspace(s[i]):
            return False
   
    return True

## 连接向量
cdef string join_vector(const vector[string]& vec, const string& delimiter) noexcept nogil:
    if vec.empty():
        return string()
    cdef string result = vec[0]
    for i in range(1, vec.size()):
        result += delimiter
        result += vec[i]
    return result

## 计算单词数
cdef size_t count_words(const string& s) noexcept nogil:
    if s.empty():
        return 0
    cdef size_t count = 0
    cdef bint in_word = not isspace(s[0])
    if in_word:
        count = 1
    for i in range(1, s.size()):
        if not isspace(s[i]):
            if not in_word:
                count += 1
                in_word = True
        else:
            in_word = False
    return count

## 转换为小写
cdef string to_lower(const string& s) noexcept nogil:
    cdef string lower_s = s
    for i in range(lower_s.size()):
        lower_s[i] = tolower(lower_s[i])
    return lower_s

## 计算停用词数量
cdef size_t count_stopwords(const string& s, const stl_set[string]& stoplist) noexcept nogil:
    cdef size_t count = 0
    cdef string word
    cdef size_t start = 0
    cdef size_t i = 0
    while i < s.size():
        if isspace(s[i]):
            if start < i:
                word = to_lower(s.substr(start, i - start))
                if stoplist.find(word) != stoplist.end():
                    count += 1
            start = i + 1
        i += 1
    if start < i:
        word = to_lower(s.substr(start, i - start))
        if stoplist.find(word) != stoplist.end():
            count += 1
    return count

## 连接 DOM 路径
cdef string join_path_nogil(const vector[string]& paths, const string& delimiter) noexcept nogil:
    return join_vector(paths, delimiter)

# 段落提取的核心逻辑
cdef class ParagraphExtractor:
    cdef vector[Paragraph] paragraphs
    cdef vector[string] dom_paths
    cdef Paragraph current_paragraph
    cdef bint in_link
    cdef bint br_flag
    cdef bint head_tag_count

    def __init__(self):
        self.paragraphs.clear()
        self.dom_paths.clear()
        self.in_link = False
        self.br_flag = False
        self._start_new_paragraph(string(<char*>b'start_dom'))

    cdef void _start_new_paragraph(self, string dom_path) noexcept nogil:
        if self.current_paragraph.text_nodes.size() > 0:
            self.paragraphs.push_back(self.current_paragraph)
        self.current_paragraph = Paragraph(
            text_nodes=vector[string](),
            dom_path=dom_path,
            chars_count_in_links=0,
            tags_count=0,
            head_tag_count=self.head_tag_count,
        )
        self.br_flag = False

    cdef void append_text(self, const string& content, bint check_blank) noexcept nogil:
        cdef string clean_content
        clean_content = normalize_whitespace(content)
        if check_blank and is_blank(clean_content):
            return

        self.current_paragraph.text_nodes.push_back(clean_content)
        if self.in_link:
            self.current_paragraph.chars_count_in_links += clean_content.size()
        self.br_flag = False

    cdef void process_node(self, lxb_dom_node_t* node, bint is_end_tag) noexcept nogil:
        cdef string tag_name
        cdef lxb_dom_character_data_t* char_data
        if node.type == LXB_DOM_NODE_TYPE_ELEMENT:
            tag_name = string(<const char*>lxb_dom_element_qualified_name(<lxb_dom_element_t*>node, NULL))
            
            # 处理无文本也需要处理的节点
            if node.local_name == LXB_TAG_BR:
                if self.br_flag:
                    # 保持 dom_path 和 深度
                    self._start_new_paragraph(self.current_paragraph.dom_path)
                else:
                    self.append_text(b" ", False)
                self.br_flag = True
            
            # 如果无子节点，肯定也没有文本，直接跳过
            if not node.first_child:
                return

            # 处理有子节点的情况，如果有子节点说明肯定会进入&退出各一次

            # 进入，当前为element node，准备进text节点
            if not is_end_tag:
                if PARAGRAPH_TAGS.find(node.local_name) != PARAGRAPH_TAGS.end():
                    self.dom_paths.push_back(tag_name)
                    if HEAD_STR_TAGS.find(tag_name) != HEAD_STR_TAGS.end():
                        self.head_tag_count += 1
                    self._start_new_paragraph(join_path_nogil(self.dom_paths, b"."))
                else:
                    if node.local_name == LXB_TAG_A:
                        self.in_link = True
                    self.current_paragraph.tags_count += 1
            # 退出，上一个访问的是 last_child，准备继续往上走
            else:
                
                # 如果是 PARAGRAPH_TAGS 退出，封装，回到上一个的tag
                if PARAGRAPH_TAGS.find(node.local_name) != PARAGRAPH_TAGS.end():
                    if HEAD_STR_TAGS.find(self.dom_paths.back()) != HEAD_STR_TAGS.end():
                        self.head_tag_count -= 1
                    self.dom_paths.pop_back()
                    self._start_new_paragraph(join_path_nogil(self.dom_paths, b"."))
                if node.local_name == LXB_TAG_A:
                    self.in_link = False

        # 文本就添加
        elif node.type == LXB_DOM_NODE_TYPE_TEXT:
            char_data = <lxb_dom_character_data_t*>node
            self.append_text(string(<const char*>char_data.data.data, char_data.data.length), True)

    cdef vector[Paragraph] extract(self, HTMLTree tree, string skip_selector) noexcept nogil:
        cdef lxb_dom_node_t* root = <lxb_dom_node_t*>tree.dom_document.body
        cdef lxb_dom_node_t* node = root
        cdef size_t depth = 0
        cdef bint is_end_tag = False

        # Select all blacklisted elements and store them in a set
        cdef lxb_dom_collection_t* blacklist_coll = query_selector_all_impl(root, tree,
                                                                            skip_selector.data(), skip_selector.size(), 30)
        cdef stl_set[lxb_dom_node_t*] blacklisted_nodes
        if blacklist_coll != NULL:
            for i in range(lxb_dom_collection_length(blacklist_coll)):
                blacklisted_nodes.insert(lxb_dom_collection_node(blacklist_coll, i))
            lxb_dom_collection_destroy(blacklist_coll, True)

        while node:
            if (node.type != LXB_DOM_NODE_TYPE_ELEMENT and node.type != LXB_DOM_NODE_TYPE_TEXT) or \
                blacklisted_nodes.find(node) != blacklisted_nodes.end():
                is_end_tag = True
                node = next_node(root, node, &depth, &is_end_tag)
                continue
            self.process_node(node, is_end_tag)
            node = next_node(root, node, &depth, &is_end_tag)

        self._start_new_paragraph(string(<char*>b'end_dom'))  # 结束时保存最后一个段落
        return self.paragraphs

# 分类函数
cdef void classify_paragraphs(vector[Paragraph]& paragraphs, const stl_set[string]& stoplist,
                              double length_low, double length_high, double stopwords_low,
                              double stopwords_high, double max_link_density, bint no_headings) noexcept nogil:
    cdef size_t i
    cdef Paragraph* p
    cdef size_t length
    for i in range(paragraphs.size()):
        p = &paragraphs[i]
        length = p.text_py_length
        p.stopwords_count = count_stopwords(p.text, stoplist)
        p.stopword_density = <double>p.stopwords_count / p.words_count if p.words_count > 0 else 0.0

        if p.links_density > max_link_density:
            p.cf_class = CLASS_BAD
        elif p.text.find(b'\xc2\xa9') != strnpos or p.text.find(b'&copy') != strnpos:  # © 字符或&copy
            p.cf_class = CLASS_BAD
        elif length < length_low:
            if p.chars_count_in_links > 0:
                p.cf_class = CLASS_BAD
            else:
                p.cf_class = CLASS_SHORT
        elif p.stopword_density >= stopwords_high:
            if length > length_high:
                p.cf_class = CLASS_GOOD
            else:
                p.cf_class = CLASS_NEARGOOD
        elif p.stopword_density >= stopwords_low:
            p.cf_class = CLASS_NEARGOOD
        else:
            p.cf_class = CLASS_BAD

cdef void revise_paragraph_classification_fast(vector[Paragraph]& paragraphs, size_t max_heading_distance) noexcept nogil:
    cdef size_t n = paragraphs.size()
    cdef size_t i
    cdef Paragraph* p
    cdef int distance
    cdef vector[int] next_good_pos
    cdef vector[int] next_good_or_bad
    cdef vector[int] next_good_or_bad_or_neargood
    cdef vector[int] prev_good_or_bad
    cdef vector[int] prev_good_or_bad_or_neargood
    cdef vector[int] new_classes
    cdef vector[int] distance_prefix_sum
    cdef int prev_idx
    cdef int next_idx
    cdef int prev_neighbour
    cdef int next_neighbour
    cdef int prev_neargood_idx
    cdef int next_neargood_idx
    cdef int prev_with_neargood
    cdef int next_with_neargood

    # 复制 cf_class 到 class_type
    for i in range(n):
        paragraphs[i].class_type = paragraphs[i].cf_class

    next_good_pos.resize(n, n)
    next_good_or_bad.resize(n, n)
    next_good_or_bad_or_neargood.resize(n, n)
    prev_good_or_bad.resize(n, -1)
    prev_good_or_bad_or_neargood.resize(n, -1)
    new_classes.resize(n, -1)
    distance_prefix_sum.resize(n + 1, 0)

    for i in range(n):
        p = &paragraphs[i]
        distance_prefix_sum[i+1] = distance_prefix_sum[i] + p.text_py_length

    for i in range(n-1, -1, -1):
        if paragraphs[i].class_type == CLASS_GOOD:
            next_good_pos[i] = i
        elif i < n-1:
            next_good_pos[i] = next_good_pos[i+1]
        else:
            next_good_pos[i] = n

    # 步骤 1: 处理好的标题
    for i in range(n):
        p = &paragraphs[i]

        if p.is_heading and p.cf_class == CLASS_SHORT:
            if i + 1 < n and next_good_pos[i + 1] < n:
                distance = distance_prefix_sum[next_good_pos[i + 1]] - distance_prefix_sum[i + 1]
                if distance <= max_heading_distance:
                    p.class_type = CLASS_NEARGOOD

    for i in range(n-2, -1, -1):
        if paragraphs[i+1].class_type in [CLASS_GOOD, CLASS_BAD]:
            prev_good_or_bad[i] = i + 1
            prev_good_or_bad_or_neargood[i] = i + 1
        else:
            prev_good_or_bad[i] = prev_good_or_bad[i + 1]
        if paragraphs[i+1].class_type in [CLASS_GOOD, CLASS_BAD, CLASS_NEARGOOD]:
            prev_good_or_bad_or_neargood[i] = i + 1
        else:
            prev_good_or_bad_or_neargood[i] = prev_good_or_bad_or_neargood[i + 1]

    for i in range(1, n):
        if paragraphs[i-1].class_type in [CLASS_GOOD, CLASS_BAD]:
            next_good_or_bad[i] = i - 1
            next_good_or_bad_or_neargood[i] = i - 1
        else:
            next_good_or_bad[i] = next_good_or_bad[i - 1]
        if paragraphs[i-1].class_type in [CLASS_GOOD, CLASS_BAD, CLASS_NEARGOOD]:
            next_good_or_bad_or_neargood[i] = i - 1
        else:
            next_good_or_bad_or_neargood[i] = next_good_or_bad_or_neargood[i - 1]

    # 步骤 2: 分类短段落
    for i in range(n):
        p = &paragraphs[i]
        if p.class_type == CLASS_SHORT:
            prev_idx = next_good_or_bad[i]
            next_idx = prev_good_or_bad[i]
            prev_neighbour = paragraphs[prev_idx].class_type if prev_idx >= 0 and prev_idx < n else CLASS_BAD
            next_neighbour = paragraphs[next_idx].class_type if next_idx >= 0 and next_idx < n else CLASS_BAD
            if prev_neighbour == CLASS_GOOD and next_neighbour == CLASS_GOOD:
                p.class_type = CLASS_GOOD
            elif prev_neighbour == CLASS_BAD and next_neighbour == CLASS_BAD:
                p.class_type = CLASS_BAD
            else:
                prev_neargood_idx = next_good_or_bad_or_neargood[i]
                next_neargood_idx = prev_good_or_bad_or_neargood[i]
                prev_with_neargood = paragraphs[prev_neargood_idx].class_type if prev_neargood_idx >= 0 and prev_neargood_idx < n else CLASS_BAD
                next_with_neargood = paragraphs[next_neargood_idx].class_type if next_neargood_idx >= 0 and next_neargood_idx < n else CLASS_BAD
                if (prev_neighbour == CLASS_BAD and prev_with_neargood == CLASS_NEARGOOD) or \
                (next_neighbour == CLASS_BAD and next_with_neargood == CLASS_NEARGOOD):
                    new_classes[i] = CLASS_GOOD
                else:
                    new_classes[i] = CLASS_BAD

    for i in range(n):
        if new_classes[i] != -1:
            p = &paragraphs[i]
            p.class_type = new_classes[i]

    # 步骤 3: 修订 neargood 段落
    for i in range(n):
        p = &paragraphs[i]
        if p.class_type == CLASS_NEARGOOD:
            prev_idx = next_good_or_bad[i]
            next_idx = prev_good_or_bad[i]
            prev_neighbour = paragraphs[prev_idx].class_type if prev_idx >= 0 and prev_idx < n else CLASS_BAD
            next_neighbour = paragraphs[next_idx].class_type if next_idx >= 0 and next_idx < n else CLASS_BAD
            if prev_neighbour == CLASS_BAD and next_neighbour == CLASS_BAD:
                p.class_type = CLASS_BAD
            else:
                p.class_type = CLASS_GOOD

    # 步骤 4: 处理更多好的标题
    for i in range(n-1, -1, -1):
        if paragraphs[i].class_type == CLASS_GOOD:
            next_good_pos[i] = i
        elif i < n-1:
            next_good_pos[i] = next_good_pos[i+1]
        else:
            next_good_pos[i] = n

    for i in range(n):
        p = &paragraphs[i]
        if p.is_heading and p.class_type == CLASS_BAD and p.cf_class != CLASS_BAD:  
            if i + 1 < n and next_good_pos[i + 1] < n:
                distance = distance_prefix_sum[next_good_pos[i + 1]] - distance_prefix_sum[i + 1]
                if distance <= max_heading_distance:
                    p.class_type = CLASS_GOOD

# 主提取函数
cdef vector[Paragraph] _extract_paragraphs_impl(vector[Paragraph]& paragraphs, HTMLTree tree, stl_set[string]& stoplist,
                                                     double length_low, double length_high,
                                                     double stopwords_low, double stopwords_high,
                                                     double max_link_density, size_t max_heading_distance,
                                                     bint no_headings, string skip_selector) noexcept nogil:
    cdef size_t i
    cdef Paragraph* p
    for i in range(paragraphs.size()):
        p = &paragraphs[i]
        p.words_count = count_words(p.text)
        p.links_density = p.chars_count_in_links / <double>p.text_c_length if p.text_c_length > 0 else 0.0
        p.is_heading = p.head_tag_count > 0

    classify_paragraphs(paragraphs, stoplist, length_low, length_high, stopwords_low, stopwords_high, max_link_density, no_headings)
    revise_paragraph_classification_fast(paragraphs, max_heading_distance)
    return paragraphs

_stoplist_sets = {}


import re

MULTIPLE_WHITESPACE_PATTERN = re.compile(r"\s+", re.UNICODE)

def _replace_whitespace(match):
    """Normalize all spacing characters that aren't a newline to a space."""
    text = match.group()
    return "\n" if "\n" in text or "\r" in text else " "

def py_normalize_whitespace(text):
    """
    Translates multiple whitespace into single space character.
    If there is at least one new line character chunk is replaced
    by single LF (Unix new line) character.
    """
    return MULTIPLE_WHITESPACE_PATTERN.sub(_replace_whitespace, text)

def py_is_blank(string):
    """
    Returns `True` if string contains only white-space characters
    or is empty. Otherwise `False` is returned.
    """
    return not string or string.isspace()


def justext(html, stoplist=None, language="English", length_low=70, length_high=200, stopwords_low=0.30,
                            stopwords_high=0.32, max_link_density=0.2, max_heading_distance=200, no_headings=False):
    """
    从 HTML 中提取并分类段落，使用 Justext 算法。

    :param html: 输入 HTML 字符串或 HTMLTree 对象
    :param stoplist: 用于分类的停用词集合
    :param language: 用于分类的停用词语言（默认使用英文停用词表）
    :param length_low: 段落被视为"短"的最小长度
    :param length_high: 停用词密度高时段落被视为"好"的最小长度
    :param stopwords_low: "neargood"的最小停用词密度
    :param stopwords_high: "good"的最小停用词密度
    :param max_link_density: 链接密度超过此值则分类为"bad"
    :param max_heading_distance: 标题到下一个好段落的最大距离
    :param no_headings: 如果为 True，则不特别处理标题
    :return: 包含段落详情和分类的字典列表
    """
    cdef HTMLTree tree
    if isinstance(html, str):
        tree = HTMLTree.parse(html)
    elif isinstance(html, HTMLTree):
        tree = <HTMLTree>html
    else:
        raise TypeError("参数 'html' 必须是字符串或 HTMLTree 对象。")

    cdef stl_set[string] c_stoplist

    if language not in _stoplist_sets:
        if stoplist is None:
            # 创建并缓存新的停用词集合
            from justext import get_stoplist
            stoplist = frozenset(w.lower() for w in get_stoplist(language))
        c_stoplist = stl_set[string]()
        for word in stoplist:
            c_stoplist.insert(word.encode('utf-8'))
        _stoplist_sets[language] = c_stoplist
    else:
        c_stoplist = _stoplist_sets[language]

    # 在进入nogil块之前确保所有参数都已经是C类型
    cdef int c_length_low = length_low
    cdef int c_length_high = length_high
    cdef double c_stopwords_low = stopwords_low
    cdef double c_stopwords_high = stopwords_high
    cdef double c_max_link_density = max_link_density
    cdef int c_max_heading_distance = max_heading_distance
    cdef bint c_no_headings = no_headings
    cdef string skip_selector = b'script,style,button,input,select,textarea,applet,iframe'
    cdef ParagraphExtractor extractor = ParagraphExtractor()
    cdef string c_node_text

    with nogil:
        extractor.extract(tree, skip_selector)

    if extractor.paragraphs.size() == 0:
        return []
    
    for i in range(extractor.paragraphs.size()):
        text_nodes = [n.decode('utf-8', errors='replace') for n in extractor.paragraphs[i].text_nodes]
        py_text = py_normalize_whitespace("".join([node for node in text_nodes if (not py_is_blank(node)) or node == " "]).strip())
        extractor.paragraphs[i].text = py_text.encode('utf-8')
        extractor.paragraphs[i].text_py_length = len(py_text)
        extractor.paragraphs[i].text_c_length = len(extractor.paragraphs[i].text)

    with nogil:
        _extract_paragraphs_impl(extractor.paragraphs, tree, c_stoplist, c_length_low, c_length_high,
                                                c_stopwords_low, c_stopwords_high, c_max_link_density,
                                                c_max_heading_distance, c_no_headings, skip_selector)

    cdef list result = []
    for p in extractor.paragraphs:
        if p.text.empty():
            continue
        result.append({
            'text': p.text.decode('utf-8', errors='replace'),
            'dom_path': p.dom_path.decode('utf-8', errors='replace'),
            'chars_count_in_links': p.chars_count_in_links,
            'tags_count': p.tags_count,
            'head_tag_count': p.head_tag_count,
            'words_count': p.words_count,
            'stopwords_count': p.stopwords_count,
            'links_density': p.links_density,
            'stopword_density': p.stopword_density,
            'is_heading': bool(p.is_heading),
            'cf_class': CLASS_NAMES[p.cf_class],
            'class_type': CLASS_NAMES[p.class_type]
        })
    return result