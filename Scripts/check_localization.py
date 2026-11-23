#!/usr/bin/env python3
import json, pathlib, re, sys, unicodedata

ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOG = ROOT / 'Resources/Localizable.xcstrings'
INFOPLIST_CATALOG = ROOT / 'Resources/InfoPlist.xcstrings'
DIRS = ['App', 'Core', 'Platform', 'UI']
LANGUAGES = ['en', 'zh-Hans', 'zh-Hant', 'ja', 'de', 'fr', 'es', 'es-419', 'pt-BR', 'pt-PT', 'it', 'ko', 'ru', 'tr', 'hi', 'vi']

STR = r'"((?:[^"\\]|\\.)*)"'
RE_LOCALIZED = re.compile(r'String\(\s*localized:\s*(?!""")' + STR)
RE_SWIFTUI = re.compile(r'\b(?:Text|Button|Toggle|Label|Picker|TextField)\(\s*' + STR)
RE_STRING = re.compile(STR)

SKIP_FILES = set()

def unescape(s):
    return s.replace('\\"', '"').replace('\\n', '\n').replace('\\\\', '\\')

def strip_comments(text):
    out = []
    in_block = False
    for line in text.splitlines():
        s = line.strip()
        if in_block:
            out.append('')
            if '*/' in line:
                in_block = False
            continue
        if s.startswith('/*'):
            out.append('')
            if '*/' not in line:
                in_block = True
            continue
        if s.startswith('//'):
            out.append('')
            continue
        out.append(line)
    return '\n'.join(out)

def lineno_of(text, pos):
    return text.count('\n', 0, pos) + 1

def eval_multiline(block_lines, closing_indent):
    out = []
    for line in block_lines:
        line = line[closing_indent:] if len(line) >= closing_indent else line.lstrip()
        out.append(line)
    text = '\n'.join(out)
    text = re.sub(r'\\\n', '', text)
    return text

def extract_multiline(path):
    lines = pathlib.Path(path).read_text(encoding='utf-8').splitlines()
    keys = []
    i = 0
    while i < len(lines):
        if re.search(r'String\(localized:\s*"""\s*$', lines[i]):
            body = []
            j = i + 1
            while j < len(lines) and lines[j].strip() != '"""' and not lines[j].strip().startswith('""")'):
                body.append(lines[j])
                j += 1
            closing = len(lines[j]) - len(lines[j].lstrip()) if j < len(lines) else 0
            keys.append(eval_multiline(body, closing))
            i = j
        i += 1
    return keys

def contains_non_latin_letters(value):
    return any(char.isalpha() and not unicodedata.name(char, '').startswith('LATIN ')
               for char in value)

def scan():
    used, non_latin_literals = {}, []
    for d in DIRS:
        for f in sorted((ROOT / d).rglob('*.swift')):
            rel = str(f.relative_to(ROOT))
            if rel in SKIP_FILES:
                continue
            text = strip_comments(f.read_text(encoding='utf-8'))
            for rx in (RE_LOCALIZED, RE_SWIFTUI):
                for m in rx.finditer(text):
                    key = unescape(m.group(1))
                    if rx is RE_SWIFTUI and re.fullmatch(r'[a-z0-9]+(?:\.[a-z0-9]+)+', key):
                        continue
                    used.setdefault(key, []).append(f'{rel}:{lineno_of(text, m.start())}')
            for key in extract_multiline(f):
                used.setdefault(key, []).append(rel)
            for m in RE_STRING.finditer(text):
                if contains_non_latin_letters(m.group(1)):
                    non_latin_literals.append((f'{rel}:{lineno_of(text, m.start())}', m.group(1)))
    return used, non_latin_literals

def value_of(entry, lang):
    return entry.get('localizations', {}).get(lang, {}).get('stringUnit', {}).get('value')

RE_PLACEHOLDER = re.compile(r'%(?:\d+\$)?(?:@|d|lld|ld|u|f|s|%)')

def placeholder_mismatches(catalog):
    out = []
    for key, entry in catalog.items():
        expected = RE_PLACEHOLDER.findall(value_of(entry, 'en') or key)
        for lang in LANGUAGES:
            value = value_of(entry, lang)
            if value is None:
                continue
            actual = RE_PLACEHOLDER.findall(value)
            if actual != expected:
                out.append((key, lang, expected, actual))
    return out

def main():
    catalog = json.loads(CATALOG.read_text(encoding='utf-8'))['strings']
    used, non_latin_literals = scan()

    missing = {k: v for k, v in used.items() if k not in catalog}
    unused = [k for k in catalog if k not in used]
    untranslated = {lang: [k for k, v in catalog.items() if not value_of(v, lang)] for lang in LANGUAGES}
    infoplist = json.loads(INFOPLIST_CATALOG.read_text(encoding='utf-8'))['strings']
    infoplist_untranslated = {lang: [k for k, v in infoplist.items() if not value_of(v, lang)] for lang in LANGUAGES}
    placeholder_drift = placeholder_mismatches(catalog)
    non_latin_keys = [key for key in used if contains_non_latin_letters(key)]

    print(f'{len(used)} source keys, {len(catalog)} catalog entries across {len(LANGUAGES)} locales, '
          f'{len(non_latin_literals)} source literals with non-Latin letters\n')

    ok = True
    if missing:
        ok = False
        print(f'{len(missing)} source keys are missing from the catalog:')
        for k, locs in sorted(missing.items()):
            print(f'   {k[:70]!r}  ← {locs[0]}')
    for lang, keys in untranslated.items():
        if keys:
            ok = False
            print(f'\n{len(keys)} entries lack a {lang} translation:')
            for k in keys:
                print(f'   {k[:70]!r}')
    for lang, keys in infoplist_untranslated.items():
        if keys:
            ok = False
            print(f'\n{len(keys)} InfoPlist.xcstrings entries lack a {lang} translation: {keys}')
    if placeholder_drift:
        ok = False
        print(f'\n{len(placeholder_drift)} translations have placeholders that differ from the English source:')
        for k, lang, expected, actual in placeholder_drift:
            print(f'   [{lang}] {k[:60]!r}  en={expected}  {lang}={actual}')
    if non_latin_keys:
        ok = False
        print(f'\n{len(non_latin_keys)} English source keys contain non-Latin letters:')
        for k in non_latin_keys:
            print(f'   {k[:70]!r}  ← {used[k][0]}')
    if unused:
        ok = False
        print(f'\n{len(unused)} catalog entries have no detected source reference:')
        for k in unused:
            print(f'   {k[:70]!r}')

    if '--remaining' in sys.argv and non_latin_literals:
        print(f'\n{len(non_latin_literals)} source literals with non-Latin letters:')
        for loc, s in non_latin_literals:
            print(f'   {loc}  {s[:60]}')

    print()
    print('Localization checks passed.' if ok else 'Localization checks failed.')
    return 0 if ok else 1

if __name__ == '__main__':
    sys.exit(main())
