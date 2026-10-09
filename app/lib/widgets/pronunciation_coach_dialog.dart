import 'dart:async';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../theme.dart';
import '../util/pronunciation_coach.dart';
import '../util/pronunciation_hint.dart';
import '../util/pronunciation_result.dart';
import '../util/recording_bytes.dart';
import '../util/voice_playback_source.dart';

/// Read-aloud practice for a whole phrase or one selected word.
Future<void> showPronunciationCoachDialog(
  BuildContext context, {
  required String text,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _PronunciationCoachDialog(text: text.trim()),
  );
}

class _PronunciationCoachDialog extends StatefulWidget {
  const _PronunciationCoachDialog({required this.text});

  final String text;

  @override
  State<_PronunciationCoachDialog> createState() =>
      _PronunciationCoachDialogState();
}

class _PronunciationCoachDialogState extends State<_PronunciationCoachDialog> {
  final _recorder = AudioRecorder();
  final _player = AudioPlayer();

  bool _loadingModel = true;
  String? _modelError;
  bool _recording = false;
  bool _scoring = false;
  String? _scoreError;
  Timer? _elapsedTimer;
  Duration _elapsed = Duration.zero;
  int? _practiceWordIndex;
  final Map<int, PronunciationAssessment> _wordResults = {};
  PronunciationAssessment? _sentenceResult;
  String? _recordingPath;

  bool get _tooLong => widget.text.length > PronunciationAssessment.maxChars;
  bool get _unsupportedLanguage =>
      RegExp(r'[\u0400-\u04FF]').hasMatch(widget.text);
  List<RegExpMatch> get _wordMatches => RegExp(
    r"[A-Za-z0-9_]+(?:'[A-Za-z0-9_]+)*",
  ).allMatches(widget.text).toList();
  bool get _practisingWord => _practiceWordIndex != null;
  String get _targetText => _practisingWord
      ? _wordMatches[_practiceWordIndex!].group(0)!
      : widget.text;
  PronunciationAssessment? get _activeResult =>
      _practisingWord ? _wordResults[_practiceWordIndex!] : _sentenceResult;

  @override
  void initState() {
    super.initState();
    if (!_unsupportedLanguage) unawaited(_loadModel());
  }

  @override
  void dispose() {
    _elapsedTimer?.cancel();
    unawaited(_disposeAudio());
    super.dispose();
  }

  Future<void> _disposeAudio() async {
    if (_recording) {
      try {
        final path = await _recorder.stop();
        final recordedPath = path ?? _recordingPath;
        if (recordedPath != null && recordedPath.isNotEmpty) {
          await deleteRecordingFile(recordedPath);
        }
      } catch (_) {}
    }
    await _recorder.dispose();
    await _player.dispose();
  }

  Future<void> _loadModel() async {
    try {
      await ensurePronunciationServer();
      if (!mounted) return;
      setState(() {
        _loadingModel = false;
        _modelError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingModel = false;
        _modelError = e is StateError ? e.message : 'Could not start the model';
      });
    }
  }

  Future<void> _start() async {
    if (_recording || _scoring || _loadingModel || _modelError != null) return;
    await _player.stop();
    try {
      if (!await _recorder.hasPermission()) {
        _fail('Microphone permission required');
        return;
      }
      final devices = await _recorder.listInputDevices();
      if (devices.isEmpty) {
        _fail('No microphone detected');
        return;
      }
      final dir = await getTemporaryDirectory();
      final out = p.join(
        dir.path,
        'privet-pronounce-${DateTime.now().millisecondsSinceEpoch}.wav',
      );
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
        ),
        path: out,
      );
      if (!mounted) return;
      _elapsedTimer?.cancel();
      setState(() {
        _recording = true;
        _recordingPath = out;
        _elapsed = Duration.zero;
        _scoreError = null;
      });
      _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() => _elapsed += const Duration(seconds: 1));
      });
    } catch (e) {
      _fail('Could not start the microphone');
    }
  }

  Future<void> _stop() async {
    if (!_recording) return;
    _elapsedTimer?.cancel();
    String? path;
    try {
      path = await _recorder.stop();
    } catch (_) {
      _fail('Не удалось остановить запись. Проверьте микрофон и повторите.');
      return;
    }
    final recordedPath = path ?? _recordingPath;
    _recordingPath = null;
    if (!mounted) {
      if (recordedPath != null && recordedPath.isNotEmpty) {
        await deleteRecordingFile(recordedPath);
      }
      return;
    }
    setState(() {
      _recording = false;
      _scoring = true;
    });
    if (recordedPath == null || recordedPath.isEmpty) {
      _fail('Recording produced no file');
      return;
    }
    try {
      final bytes = await readRecordingBytes(recordedPath);
      if (bytes.length < 1000) {
        _fail(
          _practisingWord
              ? 'Запись слишком короткая — произнесите слово ещё раз'
              : 'Запись слишком короткая — прочитайте всё предложение',
        );
        return;
      }
      final result = await assessPronunciation(bytes, _targetText);
      if (!mounted) return;
      setState(() {
        _scoring = false;
        if (_practiceWordIndex case final index?) {
          _wordResults[index] = result;
        } else {
          _sentenceResult = result;
        }
      });
      try {
        await _playReference(result.referenceWav);
      } catch (_) {
        if (mounted) {
          setState(() {
            _scoreError =
                'Оценка готова, но эталон не воспроизвёлся. Попробуйте кнопку «Послушать эталон».';
          });
        }
      }
    } catch (e) {
      _fail(e is StateError ? e.message : 'Could not score the recording');
    } finally {
      await deleteRecordingFile(recordedPath);
    }
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _recording = false;
      _scoring = false;
      _scoreError = message;
    });
  }

  Future<void> _playReference(Uint8List wav) async {
    if (wav.isEmpty) return;
    final source = await voicePlaybackSource(wav, 'audio/wav');
    await _player.stop();
    await _player.play(source);
  }

  String _clock() {
    final s = _elapsed.inSeconds;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  void _showSentence() {
    if (_recording || _scoring) return;
    setState(() {
      _practiceWordIndex = null;
      _scoreError = null;
    });
  }

  void _showWord(int index) {
    if (_recording || _scoring) return;
    setState(() {
      _practiceWordIndex = index;
      _scoreError = null;
    });
  }

  void _practiceFirstMistake() {
    final result = _sentenceResult;
    if (result == null) return;
    for (var i = 0; i < _wordMatches.length; i++) {
      final word = result.wordAtPosition(i);
      if (word != null && !word.ok) {
        _showWord(i);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = _activeResult;
    final screen = MediaQuery.sizeOf(context);
    return Dialog(
      backgroundColor: PrivetTheme.panel,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: PrivetTheme.line),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 720,
          maxHeight: screen.height - 40,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 18, 12, 12),
              child: Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: PrivetTheme.mist,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.record_voice_over_rounded,
                      size: 21,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Тренировка произношения',
                          style: GoogleFonts.ibmPlexSans(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          _practisingWord
                              ? 'Отработайте слово, затем вернитесь к предложению'
                              : 'Читайте текст целиком или выберите трудное слово',
                          style: GoogleFonts.ibmPlexSans(
                            fontSize: 13,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Закрыть',
                    onPressed: _scoring || _recording
                        ? null
                        : () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: PrivetTheme.line),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _PracticeSwitcher(
                      wordMode: _practisingWord,
                      enabled: !_recording && !_scoring,
                      onSentence: _showSentence,
                      onWord: () {
                        final sentence = _sentenceResult;
                        if (sentence != null && !sentence.passed) {
                          _practiceFirstMistake();
                        } else if (_wordMatches.isNotEmpty) {
                          _showWord(0);
                        }
                      },
                    ),
                    const SizedBox(height: 18),
                    _ReadingCard(
                      fullText: widget.text,
                      targetText: _targetText,
                      wordMode: _practisingWord,
                      sentenceResult: _sentenceResult,
                    ),
                    if (_wordMatches.isNotEmpty) ...[
                      const SizedBox(height: 14),
                      _WordPicker(
                        matches: _wordMatches,
                        sentenceResult: _sentenceResult,
                        wordResults: _wordResults,
                        selected: _practiceWordIndex,
                        enabled: !_recording && !_scoring,
                        onSelected: _showWord,
                      ),
                    ],
                    const SizedBox(height: 20),
                    if (_unsupportedLanguage)
                      const _ErrorBox(
                        message:
                            'Эта тренировка проверяет только английскую речь. Уберите русский текст и оставьте английскую фразу.',
                      )
                    else if (_tooLong && !_practisingWord)
                      const Text(
                        'Текст длиннее 300 знаков. Выберите отдельное слово или сократите текст до одного-двух предложений.',
                      )
                    else if (_loadingModel)
                      const Text('Загружаю модель произношения…')
                    else if (_modelError != null)
                      Text(
                        _modelError!,
                        style: TextStyle(color: PrivetTheme.danger),
                      )
                    else ...[
                      if (_recording)
                        Text(
                          'Говорите  ${_clock()}',
                          style: GoogleFonts.ibmPlexSans(
                            color: PrivetTheme.danger,
                            fontWeight: FontWeight.w600,
                          ),
                        )
                      else if (_scoring)
                        const _BusyStatus()
                      else if (result != null)
                        _ResultView(result: result, wordMode: _practisingWord)
                      else
                        _Hint(
                          text: _practisingWord
                              ? 'Нажмите «Записать слово» и произнесите только выделенное слово.'
                              : 'Нажмите «Записать предложение» и прочитайте весь текст сверху.',
                        ),
                      if (_scoreError != null) ...[
                        const SizedBox(height: 12),
                        _ErrorBox(message: _scoreError!),
                      ],
                      if ((!_tooLong || _practisingWord) &&
                          !_unsupportedLanguage &&
                          !_loadingModel &&
                          _modelError == null) ...[
                        const SizedBox(height: 18),
                        _Actions(
                          recording: _recording,
                          scoring: _scoring,
                          wordMode: _practisingWord,
                          hasResult: result != null,
                          hasMistakes:
                              !_practisingWord &&
                              result != null &&
                              !result.passed,
                          onStart: _start,
                          onStop: _stop,
                          onPractiseMistake: _practiceFirstMistake,
                          onPlayReference:
                              result != null && result.referenceWav.isNotEmpty
                              ? () => _playReference(result.referenceWav)
                              : null,
                        ),
                      ],
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PracticeSwitcher extends StatelessWidget {
  const _PracticeSwitcher({
    required this.wordMode,
    required this.enabled,
    required this.onSentence,
    required this.onWord,
  });

  final bool wordMode;
  final bool enabled;
  final VoidCallback onSentence;
  final VoidCallback onWord;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<bool>(
      segments: const [
        ButtonSegment(
          value: false,
          icon: Icon(Icons.short_text_rounded),
          label: Text('Всё предложение'),
        ),
        ButtonSegment(
          value: true,
          icon: Icon(Icons.spellcheck_rounded),
          label: Text('Отдельное слово'),
        ),
      ],
      selected: {wordMode},
      onSelectionChanged: enabled
          ? (selection) => selection.first ? onWord() : onSentence()
          : null,
      showSelectedIcon: false,
      style: const ButtonStyle(
        visualDensity: VisualDensity(horizontal: -1, vertical: -1),
      ),
    );
  }
}

class _ReadingCard extends StatelessWidget {
  const _ReadingCard({
    required this.fullText,
    required this.targetText,
    required this.wordMode,
    required this.sentenceResult,
  });

  final String fullText;
  final String targetText;
  final bool wordMode;
  final PronunciationAssessment? sentenceResult;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: PrivetTheme.panelElevated,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: PrivetTheme.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            wordMode ? 'ПРОИЗНЕСИТЕ ТОЛЬКО ЭТО СЛОВО' : 'ПРОЧИТАЙТЕ ВЕСЬ ТЕКСТ',
            style: GoogleFonts.ibmPlexSans(
              fontSize: 11,
              letterSpacing: 0.9,
              fontWeight: FontWeight.w700,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 10),
          if (wordMode)
            SelectableText(
              targetText,
              style: GoogleFonts.ibmPlexSans(
                fontSize: 34,
                height: 1.2,
                fontWeight: FontWeight.w700,
              ),
            )
          else
            _SentenceText(text: fullText, result: sentenceResult),
        ],
      ),
    );
  }
}

class _WordPicker extends StatelessWidget {
  const _WordPicker({
    required this.matches,
    required this.sentenceResult,
    required this.wordResults,
    required this.selected,
    required this.enabled,
    required this.onSelected,
  });

  final List<RegExpMatch> matches;
  final PronunciationAssessment? sentenceResult;
  final Map<int, PronunciationAssessment> wordResults;
  final int? selected;
  final bool enabled;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Слова · нажмите на любое, чтобы потренировать',
          style: GoogleFonts.ibmPlexSans(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 7,
          runSpacing: 7,
          children: [
            for (var index = 0; index < matches.length; index++)
              _WordChip(
                text: matches[index].group(0)!,
                selected: selected == index,
                state: _stateFor(index),
                onTap: enabled ? () => onSelected(index) : null,
              ),
          ],
        ),
      ],
    );
  }

  _WordState _stateFor(int index) {
    final wordResult = wordResults[index];
    if (wordResult != null) {
      return wordResult.passed ? _WordState.mastered : _WordState.wrong;
    }
    final sentence = sentenceResult;
    final word = sentence?.wordAtPosition(index);
    if (word == null) {
      return _WordState.unchecked;
    }
    return word.ok ? _WordState.correct : _WordState.wrong;
  }
}

enum _WordState { unchecked, correct, wrong, mastered }

class _WordChip extends StatelessWidget {
  const _WordChip({
    required this.text,
    required this.selected,
    required this.state,
    required this.onTap,
  });

  final String text;
  final bool selected;
  final _WordState state;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final correct = state == _WordState.correct || state == _WordState.mastered;
    final wrong = state == _WordState.wrong;
    final color = correct
        ? const Color(0xFF5BD68A)
        : wrong
        ? PrivetTheme.danger
        : Theme.of(context).colorScheme.onSurfaceVariant;
    return Material(
      color: selected
          ? PrivetTheme.mist
          : color.withValues(alpha: correct || wrong ? 0.11 : 0.06),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? color : color.withValues(alpha: 0.35),
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (correct || wrong) ...[
                Icon(
                  correct ? Icons.check_circle_rounded : Icons.cancel_rounded,
                  size: 15,
                  color: color,
                ),
                const SizedBox(width: 5),
              ],
              Text(
                text,
                style: GoogleFonts.ibmPlexSans(
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                  color: correct || wrong ? color : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.info_outline_rounded,
          size: 19,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: GoogleFonts.ibmPlexSans(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

class _BusyStatus extends StatelessWidget {
  const _BusyStatus();

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: [
        SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        SizedBox(width: 10),
        Text('Сравниваю произношение с эталоном…'),
      ],
    );
  }
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: PrivetTheme.danger.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: PrivetTheme.danger.withValues(alpha: 0.35)),
      ),
      child: Text(message, style: TextStyle(color: PrivetTheme.danger)),
    );
  }
}

class _Actions extends StatelessWidget {
  const _Actions({
    required this.recording,
    required this.scoring,
    required this.wordMode,
    required this.hasResult,
    required this.hasMistakes,
    required this.onStart,
    required this.onStop,
    required this.onPractiseMistake,
    required this.onPlayReference,
  });

  final bool recording;
  final bool scoring;
  final bool wordMode;
  final bool hasResult;
  final bool hasMistakes;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final VoidCallback onPractiseMistake;
  final VoidCallback? onPlayReference;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 9,
      runSpacing: 9,
      children: [
        if (recording)
          FilledButton.icon(
            onPressed: onStop,
            style: FilledButton.styleFrom(backgroundColor: PrivetTheme.danger),
            icon: const Icon(Icons.stop_rounded),
            label: const Text('Остановить и проверить'),
          )
        else
          FilledButton.icon(
            onPressed: scoring ? null : onStart,
            icon: const Icon(Icons.mic_rounded),
            label: Text(
              hasResult
                  ? wordMode
                        ? 'Повторить слово'
                        : 'Повторить предложение'
                  : wordMode
                  ? 'Записать слово'
                  : 'Записать предложение',
            ),
          ),
        if (!recording && hasMistakes)
          OutlinedButton.icon(
            onPressed: scoring ? null : onPractiseMistake,
            icon: const Icon(Icons.spellcheck_rounded),
            label: const Text('Отработать ошибки'),
          ),
        if (!recording && onPlayReference != null)
          TextButton.icon(
            onPressed: scoring ? null : onPlayReference,
            icon: const Icon(Icons.volume_up_rounded),
            label: const Text('Послушать эталон'),
          ),
      ],
    );
  }
}

class _SentenceText extends StatelessWidget {
  const _SentenceText({required this.text, required this.result});

  final String text;
  final PronunciationAssessment? result;

  @override
  Widget build(BuildContext context) {
    final style = GoogleFonts.ibmPlexSans(fontSize: 21, height: 1.45);
    if (result == null) return SelectableText(text, style: style);
    var next = 0;
    var wordIndex = 0;
    final spans = <InlineSpan>[];
    for (final match in RegExp(
      r"[A-Za-z0-9_]+(?:'[A-Za-z0-9_]+)*",
    ).allMatches(text)) {
      if (match.start > next) {
        spans.add(TextSpan(text: text.substring(next, match.start)));
      }
      final assessed = result!.wordAtPosition(wordIndex);
      final wrong = assessed != null && !assessed.ok;
      final correct = assessed != null && assessed.ok;
      spans.add(
        TextSpan(
          text: match.group(0),
          style: style.copyWith(
            color: wrong
                ? PrivetTheme.danger
                : correct
                ? const Color(0xFF5BD68A)
                : null,
            fontWeight: wrong || correct ? FontWeight.w700 : null,
            decoration: wrong ? TextDecoration.underline : null,
            decorationColor: wrong ? PrivetTheme.danger : null,
          ),
        ),
      );
      wordIndex++;
      next = match.end;
    }
    if (next < text.length) spans.add(TextSpan(text: text.substring(next)));
    return SelectableText.rich(TextSpan(style: style, children: spans));
  }
}

class _ResultView extends StatelessWidget {
  const _ResultView({required this.result, required this.wordMode});

  final PronunciationAssessment result;
  final bool wordMode;

  @override
  Widget build(BuildContext context) {
    final correct = result.words.where((word) => word.ok).length;
    final problemWords = result.words.where((word) => !word.ok).toList();
    final success = const Color(0xFF5BD68A);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: (result.passed ? success : PrivetTheme.danger).withValues(
          alpha: 0.08,
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: (result.passed ? success : PrivetTheme.danger).withValues(
            alpha: 0.3,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                result.passed
                    ? Icons.check_circle_rounded
                    : Icons.tips_and_updates_rounded,
                color: result.passed ? success : PrivetTheme.danger,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  result.passed
                      ? wordMode
                            ? 'Слово произнесено правильно'
                            : 'Отлично — всё предложение совпало'
                      : wordMode
                      ? 'Нужно поправить произношение'
                      : 'Правильно: $correct из ${result.words.length} слов',
                  style: GoogleFonts.ibmPlexSans(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: result.passed ? success : null,
                  ),
                ),
              ),
            ],
          ),
          if (!result.passed) ...[
            const SizedBox(height: 12),
            for (var index = 0; index < problemWords.length; index++)
              _WordBreakdown(word: problemWords[index], startOpen: index == 0),
            Text(
              wordMode
                  ? 'Послушайте эталон и повторяйте слово до зелёной отметки.'
                  : 'Красные слова можно тренировать отдельно — нажмите на слово выше.',
              style: GoogleFonts.ibmPlexSans(
                fontSize: 13,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _WordBreakdown extends StatefulWidget {
  const _WordBreakdown({required this.word, required this.startOpen});

  final WordPronunciation word;
  final bool startOpen;

  @override
  State<_WordBreakdown> createState() => _WordBreakdownState();
}

class _WordBreakdownState extends State<_WordBreakdown> {
  late bool _open = widget.startOpen;

  @override
  Widget build(BuildContext context) {
    final word = widget.word;
    final hint = pronunciationHint(word);
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: PrivetTheme.panel.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  word.word,
                  style: GoogleFonts.ibmPlexSans(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: PrivetTheme.danger,
                  ),
                ),
                const Spacer(),
                if (word.expected.isNotEmpty)
                  Flexible(
                    child: Text(
                      '/${word.expected}/ → /${word.heard.isEmpty ? '—' : word.heard}/',
                      textAlign: TextAlign.right,
                      style: GoogleFonts.ibmPlexMono(
                        fontSize: 13,
                        color: muted,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 2),
            TextButton.icon(
              onPressed: () => setState(() => _open = !_open),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 4),
              ),
              icon: Icon(
                _open ? Icons.expand_less_rounded : Icons.help_outline_rounded,
              ),
              label: Text(_open ? 'Скрыть подсказку' : 'Подсказка'),
            ),
            if (_open) ...[
              _HintBlock(title: 'Как надо', text: hint.correct),
              _HintBlock(title: 'Как прозвучало', text: hint.heard),
              _HintBlock(title: 'Как исправить', text: hint.fix),
            ],
          ],
        ),
      ),
    );
  }
}

class _HintBlock extends StatelessWidget {
  const _HintBlock({required this.title, required this.text});

  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: GoogleFonts.ibmPlexSans(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 2),
          Text(text, style: GoogleFonts.ibmPlexSans(fontSize: 14, height: 1.4)),
        ],
      ),
    );
  }
}
