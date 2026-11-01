#!/usr/bin/env python3
# Copyright 2026 ALTESSA SOLUTIONS INC.
# Use of this source code is governed by an MIT-style license that can be
# found in the LICENSE file.
"""Generate RMRender's bundled page templates; Python standard library only.

Every template is described by the code below; no template files are read.
A page refers to its template by file name, so the files are named as the
tablet names its own, and the spacings and insets are the ones a page drawn on
the tablet lines up with. The drawings themselves are this package's.
Run with --check to verify committed files without writing.
"""

import argparse
import json
from pathlib import Path


# Shelves. `Lines` and `Grids` are the ones `TemplateStore.ruledTemplates`
# offers as paper to write along; the other two never are.
LINES, GRIDS, PLANNERS, CREATIVE = 'Lines', 'Grids', 'Planners', 'Creative'

# Colours for the parts that are not plain ruling. A path that states neither
# a width nor a colour is drawn in the renderer's own template grey.
FRAME = '#8C8C8C'
DOT = '#262626'
ACCENT = '#5A5A5A'


# MARK: - Values and items


def num(value):
    """A coordinate as the JSON carries it: integral values without a point,
    the rest rounded so that the output never depends on float noise."""
    if isinstance(value, str):
        return value
    rounded = round(float(value), 4)
    return int(rounded) if rounded == int(rounded) else rounded


def plus(base, offset):
    """`base + offset` as an expression, folding the sign of the offset."""
    if isinstance(base, (int, float)) and isinstance(offset, (int, float)):
        return num(base + offset)
    if isinstance(offset, (int, float)):
        if offset == 0:
            return base
        sign = '-' if offset < 0 else '+'
        return f'{base} {sign} {num(abs(offset))}'
    return f'{base} + {offset}'


def styled(item, weight=None, ink=None, fill=None):
    if weight is not None:
        item['strokeWidth'] = num(weight)
    if ink is not None:
        item['strokeColor'] = ink
    if fill is not None:
        item['fillColor'] = fill
    return item


def strokes(*runs, closed=False, **style):
    """One path of separate runs; each run is a list of (x, y) points."""
    data = []
    for run in runs:
        for index, (x, y) in enumerate(run):
            data += ['M' if index == 0 else 'L', num(x), num(y)]
        if closed:
            data.append('Z')
    return styled({'type': 'path', 'data': data}, **style)


def segment(x1, y1, x2, y2, **style):
    return strokes([(x1, y1), (x2, y2)], **style)


def rectangle(x, y, width, height, **style):
    right, bottom = plus(x, width), plus(y, height)
    return strokes([(x, y), (right, y), (right, bottom), (x, bottom)], closed=True, **style)


def tile(children, x=0, y=0, width=None, height=None, rows=None, columns=None):
    box = {'x': num(x), 'y': num(y)}
    if width is not None:
        box['width'] = num(width)
    if height is not None:
        box['height'] = num(height)
    item = {'type': 'group', 'boundingBox': box}
    if rows is not None or columns is not None:
        item['repeat'] = {}
        if rows is not None:
            item['repeat']['rows'] = num(rows)
        if columns is not None:
            item['repeat']['columns'] = num(columns)
    item['children'] = children
    return item


def label(text, size, x, y):
    return {'type': 'text', 'text': text, 'fontSize': num(size), 'position': {'x': num(x), 'y': num(y)}}


# A compact sheet: the phone and small-tablet canvases, under a thousand units
# on a side. The tablet's own canvases are well over that on both sides, and on
# them every template draws with its wide values.
COMPACT = ('compact', 'templateWidth < 1000 || templateHeight < 1000')
# Narrow by width alone: what decides whether columns still fit side by side.
NARROW = ('narrow', 'templateWidth < 1000')
# What a layout that shrinks to fit keeps clear on either side.
SIDE = 60


def pick(compact, wide, flag='compact'):
    """One value on a compact sheet and another everywhere else."""
    return f'{flag} ? {num(compact)} : {num(wide)}'


def at_most(value, ceiling):
    """`value`, or `ceiling` where the value is larger."""
    return f'{value} < {num(ceiling)} ? {value} : {num(ceiling)}'


def template(title, orientation, shelves, constants, items):
    return {
        'name': title,
        'orientation': orientation,
        'categories': shelves,
        'constants': [{key: num(value)} for key, value in constants],
        'items': items,
    }


# MARK: - Building blocks


def rules(top='top', pitch='pitch', toward='down', left=0, count=None):
    """Horizontal rules from `top`, one every `pitch`, to the edge of the
    sheet in one direction or `count` times."""
    run = segment(0, 0, 'parentWidth', 0)
    return tile([run], x=left, y=top, width='templateWidth', height=pitch,
                rows=count if count is not None else toward)


def upright(x, top=0, **style):
    """A vertical line from `top` down, continued onto a sheet grown past the
    page."""
    height = 'templateHeight' if top == 0 else f'templateHeight - {num(top)}'
    return tile([segment(0, 0, 0, 'parentHeight', **style)], x=x, y=top, height=height, rows='down')


def verticals(left, pitch, top=0, height='templateHeight', down=True):
    """A family of verticals from `left` rightwards, `pitch` apart."""
    return tile([segment(0, 0, 0, 'parentHeight')], x=left, y=top, width=pitch, height=height,
                rows='down' if down else None, columns='right')


def dots(left, top, toward='down'):
    """A dot at every crossing of a `pitch` lattice. Each dot is a small filled
    diamond."""
    reach = 1.5
    diamond = strokes([(0, -reach), (reach, 0), (0, reach), (-reach, 0)], closed=True, fill=DOT)
    return tile([diamond], x=left, y=top, width='pitch', height='pitch', rows=toward, columns='right')


# MARK: - Lines
#
# Ruled, squared and dotted paper fills the sheet whatever its size, so on a
# compact one only where the ruling starts changes: lower down from the top,
# and a half-sheet ruling from the middle of the sheet it is on.


def lined(orientation, title, pitch, top, margin=None, second_margin=False, toward='down', compact_top=160):
    constants = [COMPACT, ('pitch', pitch), ('top', pick(compact_top, top))]
    items = [rules(toward=toward)]
    if margin is not None:
        constants.append(('margin', margin))
        items.append(upright('margin'))
        if second_margin:
            items.append(upright('margin + 10'))
    return template(title, orientation, [LINES], constants, items)


def heading_page():
    constants = [COMPACT, ('pitch', 78.7), ('top', 287), ('headingY', 187), ('headingInset', pick(SIDE, 218))]
    items = [
        segment('headingInset', 'headingY', 'templateWidth - headingInset', 'headingY', weight=1.5, ink=FRAME),
        rules(),
    ]
    return template('Heading and rule', 'portrait', [LINES], constants, items)


def cornell_page():
    """A cue column, note lines beside it down to a summary band. On a compact
    sheet the column is a share of the width and the band sits a fixed
    height off the bottom."""
    constants = [
        COMPACT, ('pitch', 76.4), ('top', 103),
        ('cue', pick('templateWidth * 0.3', 'paperOriginX + 685')),
        ('summary', pick('templateHeight - 300', 1401)),
    ]
    items = [
        segment(0, 'summary', 'templateWidth', 'summary', weight=1.5, ink=FRAME),
        segment('cue', 0, 'cue', 'summary', weight=1.5, ink=FRAME),
        tile([segment(0, 0, 'parentWidth', 0)], x='cue', y='top', width='templateWidth - cue',
             height='pitch', rows='(summary - top) / pitch + 1'),
    ]
    return template('Cornell notes', 'portrait', [LINES], constants, items)


# MARK: - Grids and dots


def squared(orientation, title, pitch, left, top=0, edge=None, toward='down', margin=False):
    """Squares of `pitch`. With `edge`, only one side of that row is squared:
    below it (`down`) or above it (`up`)."""
    constants = [COMPACT, ('pitch', pitch), ('left', left)]
    across = 'left' if margin else 0
    if edge is None:
        constants.append(('top', top))
        items = [rules(left=across), verticals('left', 'pitch')]
    elif toward == 'down':
        constants.append(('edge', pick('templateHeight / 2', edge)))
        items = [rules(top='edge', left=across),
                 verticals('left', 'pitch', top='edge', height='templateHeight - edge')]
    else:
        constants.append(('edge', pick('templateHeight / 2', edge)))
        items = [rules(top='edge', toward='up', left=across),
                 verticals('left', 'pitch', height='edge', down=False)]
    return template(title, orientation, [GRIDS], constants, items)


def dotted(orientation, title, pitch, left, compact_left, top=0, toward='down', half=False):
    row = ('edge', pick('templateHeight / 2', top)) if half else ('top', top)
    constants = [COMPACT, ('pitch', pitch), ('left', pick(compact_left, left)), row]
    return template(title, orientation, [GRIDS], constants, [dots('left', row[0], toward)])


# MARK: - Planners


def checklist(orientation, rule, first, box_left, line_left, due_y):
    constants = [
        COMPACT, ('row', 97.4), ('rule', rule), ('first', first), ('box', 55),
        ('boxLeft', box_left), ('lineLeft', line_left), ('inset', SIDE),
    ]
    row = [
        rectangle('boxLeft', 0, 'box', 'box', ink=ACCENT, weight=1.5),
        segment('lineLeft', 'box', 'templateWidth - inset', 'box'),
    ]
    items = [
        label('Due date', 24, 'templateWidth - inset - textWidth', due_y),
        segment(0, 'rule', 'templateWidth', 'rule'),
        tile(row, x=0, y='first', width='templateWidth', height='row', rows='down'),
    ]
    return template('Checklist', orientation, [PLANNERS], constants, items)


def double_checklist():
    """Two columns of boxes, or one where two would leave too little line to
    write on."""
    constants = [
        ('row', 97.4), ('first', 228), ('box', 55), ('inset', 84),
        ('single', 'templateWidth < 1300'),
        ('half', 'single ? templateWidth : templateWidth / 2'),
    ]
    column = [
        rectangle('inset', 0, 'box', 'box', ink=ACCENT, weight=1.5),
        segment('inset + box + 72.5', 'box', 'half - inset', 'box'),
    ]
    items = [
        label('Due date', 24, 'templateWidth - inset - textWidth', 110),
        segment(0, 149, 'templateWidth', 149),
        tile(column, x=0, y='first', width='half', height='row', rows='down', columns='single ? 1 : 2'),
    ]
    return template('Checklist, two columns', 'landscape', [PLANNERS], constants, items)


def day_page(orientation):
    constants = [('hour', 116.5), ('firstHour', 379), ('gutter', 186)]
    items = [
        label('Date', 44, 60, 108),
        label('Schedule', 26, 60, 206),
        segment(0, 145, 'templateWidth', 145),
        segment(0, 245, 'templateWidth', 245),
        upright('gutter - 26', top=245),
        tile([segment(0, 0, 'parentWidth', 0)], x='gutter', y='firstHour', width='templateWidth - gutter',
             height='hour', rows='down'),
    ]
    return template('Day', orientation, [PLANNERS], constants, items)


MONDAY_FIRST = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']
SUNDAY_FIRST = MONDAY_FIRST[-1:] + MONDAY_FIRST[:-1]


def week_columns(orientation, days, title):
    """Seven equal day columns under a header, with a time column on the
    landscape sheet. On a narrow sheet the same seven dividers lie across
    instead, and the week is seven rows, each named at its left."""
    if orientation == 'portrait':
        bands, gutter, day_y, title_y = (146, 224, 312), 0, 278, 108
    else:
        bands, gutter, day_y, title_y = (152, 230, 318), 140, 284, 112
    constants = [
        NARROW, ('titleBand', bands[0]), ('numberBand', bands[1]),
        ('dayBand', pick('numberBand', bands[2], 'narrow')),
        ('gutter', gutter), ('day', '(templateWidth - gutter) / 7'),
        ('dayRow', '(templateHeight - numberBand) / 7'),
    ]
    # Counted from the top of the day area, which is repeated down a grown
    # sheet like any other ruling.
    dividers = []
    for k in range(7):
        x = f'narrow ? 0 : gutter + day * {k}'
        y = f'narrow ? dayRow * {k} : 0'
        end_x = f'narrow ? templateWidth : gutter + day * {k}'
        end_y = f'narrow ? dayRow * {k} : parentHeight'
        dividers.append([(x, y), (end_x, end_y)])
    items = [
        label('Week of', 52, 40, title_y),
        label('Week number', 24, 40, bands[0] + 52),
        strokes(*[[(0, y), ('templateWidth', y)] for y in ('titleBand', 'numberBand', 'dayBand')]),
        tile([strokes(*dividers)], y='numberBand', height='templateHeight - numberBand', rows='down'),
    ]
    if gutter:
        items.append(label('Time', 24, 'gutter / 2 - textWidth / 2', day_y))
    for index, name in enumerate(days):
        x = f'narrow ? gutter + 24 : gutter + day * {2 * index + 1} / 2 - textWidth / 2'
        y = f'narrow ? numberBand + dayRow * {index} + 40 : {day_y}'
        items.append(label(name, 30, x, y))
    return template(title, orientation, [PLANNERS], constants, items)


def week_panels():
    """Six panels on an upright sheet: two days a row, the weekend sharing the
    last panel."""
    constants = [
        ('titleBand', 146), ('days', 223), ('band', 89),
        ('block', '(templateHeight - days) / 3'), ('half', 'templateWidth / 2'),
    ]
    rows = []
    for index in range(3):
        top = 'days' if index == 0 else f'days + {index} * block'
        rows += [[(0, top), ('templateWidth', top)], [(0, f'{top} + band'), ('templateWidth', f'{top} + band')]]
    items = [
        label('Week of', 52, 40, 108),
        label('Week number', 24, 40, 198),
        strokes([(0, 'titleBand'), ('templateWidth', 'titleBand')], *rows),
        upright('half', top='days'),
        upright('half * 3 / 2', top='days + 2 * block'),
    ]
    cells = [
        ('Monday', 0, 0), ('Tuesday', 'half', 0), ('Wednesday', 0, 1), ('Thursday', 'half', 1),
        ('Friday', 0, 2), ('Saturday', 'half', 2), ('Sunday', 'half * 3 / 2', 2),
    ]
    for name, left, block in cells:
        top = 'days' if block == 0 else f'days + {block} * block'
        items.append(label(name, 28, plus(left, 24), f'{top} + band / 2 + 11'))
    return template('Week, six panels', 'portrait', [PLANNERS], constants, items)


# MARK: - Storyboards
#
# A storyboard is drawn at its full size wherever that fits, and scaled down
# as a whole — frames, gaps and caption lines alike — where it would run past
# the sides or the foot of the sheet. On the tablet's canvases it always fits.


def fitted(span, depth, side=30):
    """The constants that scale a layout `span` wide and `depth` deep down to
    the sheet, never up, keeping `side` clear either side. Thirty units is
    what the widest of them leaves on the tablet's narrower canvas, where
    they must come out at full size."""
    return [
        ('fitWidth', f'(templateWidth - {2 * side}) / {num(span)}'),
        ('fitDepth', f'(templateHeight - 20) / {num(depth)}'),
        ('fit', 'fitWidth < fitDepth ? fitWidth : fitDepth'),
        ('scale', 'fit < 1 ? fit : 1'),
        ('left', f'templateWidth / 2 - {num(span)} * scale / 2'),
    ]


def scaled(value):
    return f'{num(value)} * scale'


def storyboard(orientation, title, frame, gap, top, step, columns, rows, caption):
    """Frames with caption lines under them. `caption` is (offset below the
    frame's top, pitch, count)."""
    width, height = frame
    offset, pitch, count = caption
    span = width * columns + gap * (columns - 1)
    depth = top + (rows - 1) * step + max(height, offset + (count - 1) * pitch)
    constants = fitted(span, depth) + [
        ('frameWidth', scaled(width)), ('frameHeight', scaled(height)), ('gap', scaled(gap)),
    ]
    panel = [
        rectangle(0, 0, 'frameWidth', 'frameHeight', weight=1.5, ink=FRAME),
        tile([segment(0, 0, 'frameWidth', 0)], y=scaled(offset), width='frameWidth',
             height=scaled(pitch), rows=count),
    ]
    layout = tile(panel, x='left', y=scaled(top), width='frameWidth + gap',
                  height=scaled(step) if rows > 1 else None, rows=rows, columns=columns)
    # The whole layout again on every page's height of a sheet grown below.
    items = [tile([layout], height='templateHeight', rows='down')]
    return template(title, orientation, [CREATIVE], constants, items)


def storyboard_beside():
    width, height, gap, notes, top = 766, 1200, 73, 889, 105
    constants = fitted(width + gap + notes, top + height) + [
        ('frameWidth', scaled(width)), ('frameHeight', scaled(height)),
        ('gap', scaled(gap)), ('noteWidth', scaled(notes)),
    ]
    panel = [
        rectangle(0, 0, 'frameWidth', 'frameHeight', weight=1.5, ink=FRAME),
        tile([segment(0, 0, 'noteWidth', 0)], x='frameWidth + gap', width='noteWidth',
             height=scaled(80), rows=16),
    ]
    items = [tile([tile(panel, x='left', y=scaled(top))], height='templateHeight', rows='down')]
    return template('Storyboard, frame and notes', 'landscape', [CREATIVE], constants, items)


# MARK: - Music
#
# Staves keep their spacing on every sheet — a staff is read at its own size.
# What a narrow sheet takes in is a shorter staff, at most the width less a
# margin either side, and what a short one takes in is fewer of them: only as
# many systems as reach the foot of the sheet.


def systems(top, depth, pitch, most):
    """How many systems of `depth`, `pitch` apart from `top`, the sheet holds,
    and never more than `most`. A repeat count is truncated, so a fraction
    here is as good as a whole number."""
    return f'(templateHeight - {num(top)} - {num(depth)} - 20) / {num(pitch)} + 1', most


def staff_lines(spacing, count=5, length='parentWidth'):
    return strokes(*[[(0, index * spacing), (length, index * spacing)] for index in range(count)])


def grand_staff(orientation, title, spacing, between, system, count, top):
    """Two five-line staves a system, joined by a bracket on the left and a
    barline at either end."""
    widest, shift = (1104, 0) if orientation == 'portrait' else (1594, 10.15)
    depth = between + 4 * spacing
    fits, most = systems('top', depth, system, count)
    constants = [
        COMPACT, ('span', at_most(f'templateWidth - {2 * SIDE}', widest)),
        ('top', pick(120, top)), ('fits', fits),
        ('space', spacing), ('between', between), ('depth', depth),
        ('left', f'templateWidth / 2 - span / 2 + {num(shift)}'),
    ]
    bracket = strokes([(-6, -8), (-16, -8), (-16, 'depth + 8'), (-6, 'depth + 8')], weight=4, ink=ACCENT)
    children = [
        staff_lines(spacing),
        tile([staff_lines(spacing)], y='between', width='span'),
        strokes([(0, 0), (0, 'depth')], [('span', 0), ('span', 'depth')]),
        bracket,
    ]
    items = [tile(children, x='left', y='top', width='span', height=system, rows=at_most('fits', most))]
    return template(title, orientation, [CREATIVE], constants, items)


def staff_page():
    """Seven staves in two runs, three and then four, as the tablet spaces
    them."""
    space, depth = 26.75, 107
    runs = [(240.7, 215.3, 3), (885.3, 214.2, 4)]
    # Staves this long leave 39 units either side on the tablet.
    constants = [('span', at_most('templateWidth - 78', 1325)), ('left', 'templateWidth / 2 - span / 2')]
    staff = [staff_lines(space), strokes([(0, 0), (0, depth)], [('span', 0), ('span', depth)])]
    items = []
    for index, (top, pitch, most) in enumerate(runs):
        fits, _ = systems(top, depth, pitch, most)
        constants.append((f'fits{index}', fits))
        items.append(tile(staff, x='left', y=top, width='span', height=pitch, rows=at_most(f'fits{index}', most)))
    return template('Staff paper', 'portrait', [CREATIVE], constants, items)


def tablature(title, strings, system, count):
    depth = strings[-1]
    fits, most = systems(155, depth, system, count)
    constants = [
        ('span', at_most(f'templateWidth - {2 * SIDE}', 1103)), ('left', 'templateWidth / 2 - span / 2'),
        ('fits', fits),
    ]
    children = [
        strokes(*[[(0, y), ('span', y)] for y in strings]),
        strokes([(0, 0), (0, depth)], [('span', 0), ('span', depth)], weight=2, ink=ACCENT),
    ]
    items = [tile(children, x='left', y=155, width='span', height=system, rows=at_most('fits', most))]
    return template(title, 'portrait', [CREATIVE], constants, items)


def chord_boxes():
    """Chord diagrams four to a row where four fit, fewer where they do not,
    and as many rows as reach the foot of the sheet."""
    width, height, frets, strings, top = 208, 238, 5, 6, 154
    fits, most = systems(top, height, height + 101, 5)
    constants = [
        ('boxWidth', width), ('boxHeight', height), ('gap', 89),
        ('room', f'(templateWidth - {2 * SIDE} + gap) / (boxWidth + gap)'),
        ('across', 'room >= 4 ? 4 : room >= 3 ? 3 : room >= 2 ? 2 : 1'),
        ('left', 'templateWidth / 2 - (boxWidth * across + gap * (across - 1)) / 2'),
        ('fits', fits),
    ]
    pitch = width / (strings - 1)
    diagram = [
        strokes(*[[(index * pitch, 0), (index * pitch, height)] for index in range(strings)]),
        strokes(*[[(0, height * k / frets), (width, height * k / frets)] for k in range(1, frets + 1)]),
        segment(0, 0, width, 0, weight=5, ink=ACCENT),
        segment(40, -34, width - 40, -34),
    ]
    items = [tile(diagram, x='left', y=top, width='boxWidth + gap', height='boxHeight + 101',
                  rows=at_most('fits', most), columns='across')]
    return template('Chord boxes', 'portrait', [CREATIVE], constants, items)


# MARK: - Drawing guides


def isometric():
    """Verticals every half cell and two families of 30-degree lines through
    their crossings, each line drawn across the whole sheet."""
    reach = 18
    constants = [
        ('half', 58.4), ('rise', 67.5), ('left', 'paperOriginX - half'),
        ('run', f'half * 2 * {reach}'), ('drop', f'rise * {reach}'),
    ]
    items = [
        verticals('left', 'half'),
        tile([segment(0, 0, 'run', 'drop')], x='left', y='0 - drop', width='run', height='rise', rows='down'),
        tile([segment(0, 'drop', 'run', 0)], x='left', y='0 - drop', width='run', height='rise', rows='down'),
    ]
    return template('Isometric', 'portrait', [CREATIVE], constants, items)


def two_point_perspective():
    """A horizon across the middle with a vanishing point at either end, rays
    from each to the far edge, and verticals to stand things up on."""
    steps = 16
    constants = [('horizon', 'templateHeight / 2'), ('stride', f'templateHeight / {steps}')]
    from_left = [[(0, 'horizon'), ('templateWidth', f'stride * {k}')] for k in range(steps + 1)]
    from_right = [[('templateWidth', 'horizon'), (0, f'stride * {k}')] for k in range(steps + 1)]
    standing = [[(f'templateWidth * {k} / 8', 0), (f'templateWidth * {k} / 8', 'templateHeight')]
                for k in range(1, 8)]
    items = [
        strokes(*from_left),
        strokes(*from_right),
        strokes(*standing),
        segment(0, 'horizon', 'templateWidth', 'horizon', weight=1.5, ink=ACCENT),
    ]
    return template('Two-point perspective', 'portrait', [CREATIVE], constants, items)


def one_point_perspective():
    """One vanishing point in the middle, rays to evenly spaced points all
    round the edge, a horizon through it and a back wall around it."""
    constants = [('cx', 'templateWidth / 2'), ('cy', 'templateHeight / 2')]
    edge = []
    for k in range(9):
        across, down = f'templateWidth * {k} / 8', f'templateHeight * {k} / 8'
        edge += [(across, 0), (across, 'templateHeight')]
        if 0 < k < 8:
            edge += [(0, down), ('templateWidth', down)]
    rays = [[('cx', 'cy'), point] for point in edge]
    wall = rectangle('cx - templateWidth / 6', 'cy - templateHeight / 6',
                     'templateWidth / 3', 'templateHeight / 3', weight=1.5, ink=FRAME)
    items = [
        strokes(*rays),
        wall,
        segment(0, 'cy', 'templateWidth', 'cy', weight=1.5, ink=ACCENT),
    ]
    return template('One-point perspective', 'portrait', [CREATIVE], constants, items)


# MARK: - The set


def templates():
    portrait, landscape = 'portrait', 'landscape'
    sheet = 'paperOriginX'
    middle = 'templateHeight / 2'
    yield 'P Lines small', lined(portrait, 'Narrow rule', 52, 0)
    yield 'P Lines medium', lined(portrait, 'Medium rule', 78.7, 177.8)
    yield 'P Lines large', lined(portrait, 'Wide rule', 97, 162)
    yield 'P Margin small', lined(portrait, 'Narrow rule, margin', 52, 154, f'{sheet} + 478')
    yield 'P Margin medium', lined(portrait, 'Medium rule, margin', 78.7, 177.8, f'{sheet} + 478')
    yield 'P Margin large', lined(portrait, 'Wide rule, margin', 97, 162, f'{sheet} + 478')
    yield 'P US College', lined(portrait, 'College rule', 62, 176, f'{sheet} + 464', second_margin=True)
    yield 'P US Legal', lined(portrait, 'Legal rule', 56.5, 186, f'{sheet} + 440', second_margin=True)
    yield 'P Lined top', lined(portrait, 'Rule, upper half', 78.7, 1024, toward='up', compact_top=middle)
    yield 'P Lined bottom', lined(portrait, 'Rule, lower half', 78.7, 1005, compact_top=middle)
    yield 'P Lined heading', heading_page()
    yield 'P Cornell', cornell_page()

    yield 'LS Lines small', lined(landscape, 'Narrow rule', 52, 0)
    yield 'LS Lines medium', lined(landscape, 'Medium rule', 78.7, 177.8)
    yield 'LS Margin small', lined(landscape, 'Narrow rule, margin', 52, 154, 243)
    yield 'LS Margin medium', lined(landscape, 'Medium rule, margin', 78.7, 177.8, 243)
    yield 'LS Lines top', lined(landscape, 'Rule, upper half', 78.7, 787, toward='up', compact_top=middle)
    yield 'LS Lines bottom', lined(landscape, 'Rule, lower half', 78.7, 695, compact_top=middle)

    yield 'P Grid small', squared(portrait, 'Small squares', 52, f'{sheet} - 25')
    yield 'P Grid medium', squared(portrait, 'Medium squares', 78.3, sheet)
    yield 'P Grid large', squared(portrait, 'Large squares', 104, f'{sheet} - 78')
    yield 'P Grid margin med', squared(portrait, 'Medium squares, margin', 78.3, f'{sheet} + 469', margin=True)
    yield 'P Grid margin large', squared(portrait, 'Large squares, margin', 104, f'{sheet} + 497', margin=True)
    yield 'P Grid top', squared(portrait, 'Squares, upper half', 78.3, sheet, edge=939, toward='up')
    yield 'P Grid bottom', squared(portrait, 'Squares, lower half', 78.3, sheet, edge=1010)
    yield 'LS Grid margin med', squared(landscape, 'Medium squares, margin', 78.3, 234, margin=True)
    yield 'LS Grid margin large', squared(landscape, 'Large squares, margin', 104, 312, margin=True)
    yield 'LS Grid top', squared(landscape, 'Squares, upper half', 78.3, 0, edge=694, toward='up')
    yield 'LS Grid bottom', squared(landscape, 'Squares, lower half', 78.3, 0, edge=702)

    yield 'P Dots S', dotted(portrait, 'Dots', 42.5, f'{sheet} - 21', 6.5)
    yield 'P Dots large', dotted(portrait, 'Dots, wide', 78, f'{sheet} - 3', 17.5)
    yield 'P Dots S top', dotted(portrait, 'Dots, upper half', 42.5, f'{sheet} - 21', 6.5, 977.5, 'up', half=True)
    yield 'P Dots S bottom', dotted(portrait, 'Dots, lower half', 42.5, f'{sheet} - 21', 6.5, 978, half=True)
    yield 'LS Dots top', dotted(landscape, 'Dots, upper half', 42.5, -6.5, 5, 680.25, 'up', half=True)
    yield 'LS Dots bottom', dotted(landscape, 'Dots, lower half', 42.5, -43, 5, 724, half=True)

    yield 'P Checklist', checklist(portrait, pick(179, 192), pick(257, 270), pick(SIDE, f'{sheet} + 320'),
                                   pick(150, f'{sheet} + 445'), 'compact ? 138 : 152')
    yield 'LS Checklist', checklist(landscape, 149, 228, 85, 210, 110)
    yield 'LS Checklist double', double_checklist()
    yield 'P Day', day_page(portrait)
    yield 'LS Dayplanner', day_page(landscape)
    yield 'P Week', week_columns(portrait, MONDAY_FIRST, 'Week')
    yield 'P Week US', week_columns(portrait, SUNDAY_FIRST, 'Week, Sunday first')
    yield 'P Week 2', week_panels()
    yield 'LS Week', week_columns(landscape, MONDAY_FIRST, 'Week')
    yield 'LS Week US', week_columns(landscape, SUNDAY_FIRST, 'Week, Sunday first')

    yield 'P One storyboard', storyboard(portrait, 'Storyboard, one frame', (1164, 859), 0, 100, 0,
                                         1, 1, (955, 104, 7))
    yield 'P Two storyboards', storyboard(portrait, 'Storyboard, two frames', (1161, 473), 0, 74, 924,
                                          1, 2, (526, 57.5, 6))
    yield 'P Four storyboards', storyboard(portrait, 'Storyboard, four frames', (642, 473), 58, 74, 919,
                                           2, 2, (527, 57.5, 6))
    yield 'LS One storyboard', storyboard(landscape, 'Storyboard, one frame', (1734, 663), 0, 109, 0,
                                          1, 1, (748, 80, 7))
    yield 'LS One storyboard 2', storyboard_beside()
    yield 'LS Two storyboards', storyboard(landscape, 'Storyboard, two frames', (838, 663), 75, 58, 0,
                                           2, 1, (730, 67, 8))
    yield 'LS Four storyboards', storyboard(landscape, 'Storyboard, four frames', (838, 418), 76, 58, 663,
                                            2, 2, (482, 58, 3))

    yield 'P Piano sheet small', grand_staff(portrait, 'Grand staff, small', 18, 132, 284, 6, 155)
    yield 'P Piano sheet medium', grand_staff(portrait, 'Grand staff, medium', 22, 160, 340, 5, 155)
    yield 'P Piano sheet large', grand_staff(portrait, 'Grand staff, large', 27, 195, 433, 4, 155)
    yield 'LS Piano sheet small', grand_staff(landscape, 'Grand staff, small', 18, 132, 284, 4, 185)
    yield 'LS Piano sheet medium', grand_staff(landscape, 'Grand staff, medium', 22, 160, 360, 3, 214)
    yield 'LS Piano sheet large', grand_staff(landscape, 'Grand staff, large', 27, 195, 433, 3, 144)
    yield 'Notes', staff_page()
    yield 'P Guitar tab', tablature('Guitar tablature', [0, 32.5, 64.5, 96.5, 128.5, 161], 278, 6)
    yield 'P Bass tab', tablature('Bass tablature', [0, 30.5, 60.5, 91], 203, 8)
    yield 'P Guitar chords', chord_boxes()

    yield 'Isometric', isometric()
    yield 'Perspective1', two_point_perspective()
    yield 'Perspective2', one_point_perspective()


def layout(value, depth=0):
    """JSON with nesting broken over lines and flat values kept on one: a
    path's data or a box reads better as a row than as a column."""
    def flat(item):
        return not isinstance(item, (list, dict))

    if flat(value):
        return json.dumps(value, ensure_ascii=False)
    pad, inner = '  ' * depth, '  ' * (depth + 1)
    if isinstance(value, list):
        if all(flat(item) for item in value):
            return '[' + ', '.join(layout(item) for item in value) + ']'
        return '[\n' + ',\n'.join(inner + layout(item, depth + 1) for item in value) + '\n' + pad + ']'
    pairs = [f'{json.dumps(key)}: {layout(item, depth + 1)}' for key, item in value.items()]
    if all(flat(item) for item in value.values()):
        return '{' + ', '.join(pairs) + '}'
    return '{\n' + ',\n'.join(inner + pair for pair in pairs) + '\n' + pad + '}'


def encoded(content):
    return (layout(content) + '\n').encode('utf-8')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--output', type=Path,
                        default=Path(__file__).resolve().parents[1] / 'Sources/RMRender/Templates')
    args = parser.parse_args()
    produced = dict(templates())
    failures = []
    if not args.check:
        args.output.mkdir(parents=True, exist_ok=True)
    for name, content in sorted(produced.items()):
        path, data = args.output / f'{name}.template', encoded(content)
        if args.check:
            if not path.is_file() or path.read_bytes() != data:
                failures.append(name)
        elif not path.is_file() or path.read_bytes() != data:
            path.write_bytes(data)
    # A file nothing here produces is one the set does not vouch for.
    present = {path.stem for path in args.output.glob('*.template')} if args.output.is_dir() else set()
    strays = sorted(present - produced.keys())
    if args.check:
        failures += [f'{name} (not generated)' for name in strays]
    else:
        for name in strays:
            (args.output / f'{name}.template').unlink()
    if failures:
        parser.exit(1, 'Missing or changed templates: ' + ', '.join(failures) + '\n')
    count = len(produced)
    print(f'{count} templates verified' if args.check else f'{count} templates generated')


if __name__ == '__main__':
    main()
