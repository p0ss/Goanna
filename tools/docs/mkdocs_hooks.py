# SPDX-License-Identifier: LGPL-2.1-or-later
"""MkDocs hooks for Goanna's documentation site.

The pages link to source files (../../project/main.gd) and to measurement
records under docs/perf/ with ordinary relative links, so the links work
when the Markdown is read on GitHub or in a checkout. Neither is part of the
built site: source lives outside docs/, and docs/perf/ is excluded in
mkdocs.yml. This rewrites those links, at build time only, to the same file
on GitHub, so they work on the site too. The Markdown on disk is not changed.
"""

import posixpath
import re

LINK = re.compile(r'(\]\()(<?)([^)\s>]+)(>?)((?:\s+"[^"]*")?\))')
REF = re.compile(r'^(\s{0,3}\[[^\]]+\]:\s*)(\S+)', re.M)
FENCE = re.compile(r'^(\s*)(```|~~~).*?^\1\2\s*$', re.M | re.S)


def _github(config):
    return config['repo_url'].rstrip('/') + '/blob/main/'


def _rewrite(target, page_dir, base):
    if re.match(r'^[a-z][a-z0-9+.-]*:', target) or target.startswith(('#', '/')):
        return None
    path, sep, anchor = target.partition('#')
    if not path:
        return None
    resolved = posixpath.normpath(posixpath.join(page_dir, path))
    if resolved.startswith('../'):
        repo_path = resolved[3:]
    elif resolved == 'perf' or resolved.startswith('perf/'):
        repo_path = 'docs/' + resolved
    else:
        return None
    if path.endswith('/'):
        repo_path += '/'
    return base + repo_path + sep + anchor


def on_page_markdown(markdown, page, config, files):
    base = _github(config)
    page_dir = posixpath.dirname(page.file.src_uri)

    def link(m):
        new = _rewrite(m.group(3), page_dir, base)
        if new is None:
            return m.group(0)
        return m.group(1) + m.group(2) + new + m.group(4) + m.group(5)

    def ref(m):
        new = _rewrite(m.group(2), page_dir, base)
        return m.group(0) if new is None else m.group(1) + new

    # Leave fenced code alone: it quotes commands and source, not links.
    out, last = [], 0
    for fence in FENCE.finditer(markdown):
        chunk = markdown[last:fence.start()]
        out.append(REF.sub(ref, LINK.sub(link, chunk)))
        out.append(fence.group(0))
        last = fence.end()
    out.append(REF.sub(ref, LINK.sub(link, markdown[last:])))
    return ''.join(out)
