import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../util/composer_autocorrect.dart';
import 'composer_autocorrect_controller.dart';

/// Resolve a misspelled span under [globalPos] inside the composer field only.
///
/// Uses [RenderEditable.getBoxesForSelection] so hover/click land on the
/// painted glyphs. Do **not** stack absorbing hit targets over the field —
/// on Flutter web that steals the DOM input click and wipes the draft.
SpellIssue? spellIssueAtGlobal({
  required GlobalKey fieldKey,
  required ComposerAutocorrectController controller,
  required Offset globalPos,
}) {
  final ctx = fieldKey.currentContext;
  if (ctx == null) return null;

  RenderEditable? editable;
  void visitor(Element el) {
    if (editable != null) return;
    final ro = el.renderObject;
    if (ro is RenderEditable) {
      editable = ro;
      return;
    }
    el.visitChildren(visitor);
  }

  final rootRo = ctx.findRenderObject();
  if (rootRo is RenderEditable) {
    editable = rootRo;
  } else {
    ctx.visitChildElements(visitor);
  }
  final ed = editable;
  if (ed == null || !ed.hasSize) return null;

  final local = ed.globalToLocal(globalPos);
  if (local.dx < -8 ||
      local.dy < -8 ||
      local.dx > ed.size.width + 8 ||
      local.dy > ed.size.height + 8) {
    return null;
  }

  for (final issue in controller.spellIssues) {
    if (issue.suggestions.isEmpty) continue;
    if (issue.start < 0 ||
        issue.end > controller.text.length ||
        issue.start >= issue.end) {
      continue;
    }
    final boxes = ed.getBoxesForSelection(
      TextSelection(baseOffset: issue.start, extentOffset: issue.end),
    );
    for (final box in boxes) {
      final rect =
          Rect.fromLTRB(box.left, box.top, box.right, box.bottom).inflate(3);
      if (rect.contains(local)) return issue;
    }
  }

  final offset = ed.getPositionForPoint(globalPos).offset;
  return controller.spellIssueAt(offset);
}
