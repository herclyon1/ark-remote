#!/usr/bin/env python3
"""Write the Android stand-ins for SF Symbols that skip-ui has no Material icon for, as <name>.symbolset folders in
Sources/ArkRemote/Resources/Module.xcassets.

skip-ui draws `Image(systemName: name)` from a same-named symbolset in the app's asset catalog before its own symbol table
(Vendor/skip-ui/.../Components/Image.swift RenderSystem; skip.dev/docs/modules/skip-ui: "you can add same-named vector
symbols manually"). iOS never reads them: Image(systemName:) is always the system symbol there; actool only checks the
template, which must have a Regular-M glyph ("must have a glyph for Regular weight Medium size").

The glyphs are Material Icons (Apache License 2.0) path data, as bundled with Android Studio
(plugins/android/lib/android.jar images/material/icons/...), scaled from their 24-unit grid into the template's Regular-M
cell (96 units across, centred between Baseline-M and Capline-M).

  python3 scripts/make-symbolsets.py            # rewrites the three symbolsets
"""
import json, os, re, sys

K = 4.0                     # 24 Material units -> 96 template units
CX, CY = 1450.0, (1126 + 1055.54) / 2   # centre of the Regular-M cell (baseline 1126, capline 1055.54 at 100 pt)

def tokens(d):
    return re.findall(r'[A-Za-z]|-?(?:\d+\.?\d*|\.\d+)(?:e-?\d+)?', d)

def transform(d):
    out, cmd, i, t = [], None, 0, tokens(d)
    arity = dict(M=2, L=2, T=2, H=1, V=1, C=6, S=4, Q=4, Z=0)
    while i < len(t):
        if re.match(r'[A-Za-z]', t[i]):
            cmd = t[i]; i += 1; out.append(cmd)
            if cmd in 'Zz': continue
        n = arity[cmd.upper()]
        vals = [float(v) for v in t[i:i + n]]; i += n
        rel = cmd.islower()
        res = []
        for j, v in enumerate(vals):
            if cmd.upper() == 'H': axis = 0
            elif cmd.upper() == 'V': axis = 1
            else: axis = j % 2
            if rel: res.append(v * K)
            else: res.append((v - 12) * K + (CX if axis == 0 else CY))
        out.append(' '.join('%.3f' % x for x in res))
        if cmd == 'M': cmd = 'L'
        elif cmd == 'm': cmd = 'l'
    return ' '.join(out)

def guide(id_, x1, x2, y1, y2):
    return f'  <line id="{id_}" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="{x1}" x2="{x2}" y1="{y1}" y2="{y2}"/>'

def svg(paths, source):
    left, right = CX - 12 * K, CX + 12 * K
    lines = [guide('Baseline-S', 263, 3036, 696, 696), guide('Capline-S', 263, 3036, 625.541, 625.541),
             guide('Baseline-M', 263, 3036, 1126, 1126), guide('Capline-M', 263, 3036, 1055.54, 1055.54),
             guide('Baseline-L', 263, 3036, 1556, 1556), guide('Capline-L', 263, 3036, 1485.54, 1485.54),
             guide('left-margin-Regular-M', left, left, 1030.79, 1150.12),
             guide('right-margin-Regular-M', right, right, 1030.79, 1150.12)]
    body = '\n'.join(f'   <path class="monochrome-0 multicolor-0:tintColor hierarchical-0:primary SFSymbolsPreviewWireframe" d="{transform(p)}"/>' for p in paths)
    return f'''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
<!--{source}-->
<svg version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="3300" height="2200">
 <!--glyph: "", point size: 100.0, font version: "", template writer version: "138.0.0"-->
 <style>.SFSymbolsPreviewWireframe {{fill:none;opacity:1.0;stroke:black;stroke-width:0.5}}
</style>
 <g id="Notes">
  <text style="stroke:none;fill:black;font-family:sans-serif;font-size:13;" transform="matrix(1 0 0 1 263 322)">Medium</text>
 </g>
 <g id="Guides">
{chr(10).join(lines)}
 </g>
 <g id="Symbols">
  <g id="Regular-M">
{body}
  </g>
 </g>
</svg>
'''

def write(dest, name, paths, source):
    d = os.path.join(dest, name + '.symbolset')
    os.makedirs(d, exist_ok=True)
    open(os.path.join(d, name + '.svg'), 'w').write(svg(paths, source))
    json.dump({"info": {"author": "xcode", "version": 1}, "symbols": [{"filename": name + ".svg", "idiom": "universal"}]},
              open(os.path.join(d, 'Contents.json'), 'w'), indent=2)

if __name__ == '__main__':
    dest = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..",
                                                            "Sources", "ArkRemote", "Resources", "Module.xcassets")
    note = ('Android stand-in for the SF Symbol of this name (skip-ui takes a same-named symbolset before its Material table): '
            'Material Icons %s (Apache License 2.0), path data from Android Studio\'s bundled icon set, scaled into an SF '
            'Symbols template cell. iOS draws the system symbol: Image(systemName:) never reads the asset catalog.')
    write(dest, 'shippingbox', ["M20,2H4C3,2 2,2.9 2,4v3.01C2,7.73 2.43,8.35 3,8.7V20c0,1.1 1.1,2 2,2h14c0.9,0 2,-0.9 2,-2V8.7c0.57,-0.35 1,-0.97 1,-1.69V4C22,2.9 21,2 20,2zM19,20H5V9h14V20zM20,7H4V4h16V7z", "M9,12h6v2h-6z"], note % 'outlined inventory_2')
    write(dest, 'photo', ["M19,5v14L5,19L5,5h14m0,-2L5,3c-1.1,0 -2,0.9 -2,2v14c0,1.1 0.9,2 2,2h14c1.1,0 2,-0.9 2,-2L21,5c0,-1.1 -0.9,-2 -2,-2zM14.14,11.86l-3,3.87L9,13.14 6,17h12l-3.86,-5.14z"], note % 'outlined image')
    write(dest, 'circle.fill', ["M12,2C6.47,2 2,6.47 2,12s4.47,10 10,10 10,-4.47 10,-10S17.53,2 12,2z"], note % 'circle')
