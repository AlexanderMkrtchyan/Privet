import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../state.dart';
import '../theme.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.state});

  final PrivetState state;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool _registerMode = false;
  bool _obscure = true;
  String? _handleHint;
  Timer? _handleDebounce;
  bool _autoJoinStarted = false;

  final _handle = TextEditingController();
  final _displayName = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();

  /// Only these fields should rebuild the login form — not inbox/WS traffic.
  (bool, String?, String?, String?)? _paintKey;

  @override
  void initState() {
    super.initState();
    widget.state.sessionTick.addListener(_onSession);
    widget.state.addListener(_onLegacy);
    _paintKey = _currentPaintKey();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeAutoJoin());
  }

  (bool, String?, String?, String?) _currentPaintKey() {
    final s = widget.state;
    return (
      s.busy,
      s.error,
      s.pendingInviteHandle,
      s.invitePreview?['displayName']?.toString(),
    );
  }

  void _onSession() {
    final next = _currentPaintKey();
    if (next == _paintKey) return;
    _paintKey = next;
    if (mounted) setState(() {});
  }

  void _onLegacy() => _onSession();

  @override
  void dispose() {
    widget.state.sessionTick.removeListener(_onSession);
    widget.state.removeListener(_onLegacy);
    _handleDebounce?.cancel();
    _handle.dispose();
    _displayName.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _maybeAutoJoin() async {
    if (_autoJoinStarted || !mounted) return;
    final invite = widget.state.pendingInviteHandle;
    if (invite == null || invite.isEmpty) return;
    _autoJoinStarted = true;
    if (widget.state.invitePreview == null) {
      await widget.state.loadInvitePreview(invite);
    }
    if (!mounted || widget.state.user != null) return;
    // One tap from the link: create account + open DM with inviter.
    await widget.state.quickJoin(inviteHandle: invite);
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final invite = state.pendingInviteHandle;
    final preview = state.invitePreview;
    final inviterName = preview?['displayName'] as String? ??
        (invite != null ? '@$invite' : null);
    final hasInvite = invite != null && invite.isNotEmpty;
    final compact = MediaQuery.sizeOf(context).width < 480;
    final pad = PrivetTheme.screenPadding(context);

    return Scaffold(
      body: Stack(
        children: [
          const Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Color(0xFF0E1114),
                    Color(0xFF12181C),
                    Color(0xFF182018),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            right: -80,
            top: -40,
            child: Container(
              width: 280,
              height: 280,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: PrivetTheme.signal.withValues(alpha: 0.08),
              ),
            ),
          ),
          SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: SingleChildScrollView(
                  padding: pad,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(height: compact ? 8 : 24),
                      Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: 'P',
                              style: GoogleFonts.syne(
                                fontSize: compact ? 44 : 56,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 2,
                                color: PrivetTheme.signal,
                                height: 0.95,
                              ),
                            ),
                            TextSpan(
                              text: 'RIVET',
                              style: GoogleFonts.syne(
                                fontSize: compact ? 44 : 56,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 2,
                                color: PrivetTheme.paper,
                                height: 0.95,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        hasInvite
                            ? 'You’re invited — join in one tap.'
                            : 'Messages that feel inevitable.',
                        style: GoogleFonts.ibmPlexSans(
                          color: PrivetTheme.mist,
                          fontSize: 16,
                        ),
                      ),
                      if (hasInvite) ...[
                        const SizedBox(height: 18),
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: PrivetTheme.signal.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: PrivetTheme.signal.withValues(alpha: 0.35),
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.mail_outline_rounded,
                                color: PrivetTheme.signal,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  inviterName == null
                                      ? 'Someone invited you to Privet'
                                      : '$inviterName invited you to Privet',
                                  style: GoogleFonts.ibmPlexSans(
                                    color: PrivetTheme.paper,
                                    fontWeight: FontWeight.w600,
                                    fontSize: 14,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 28),

                      // One-click join (best for multi-user testing + invites)
                      ElevatedButton.icon(
                        onPressed: state.busy ? null : _quickJoin,
                        icon: state.busy
                            ? SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: PrivetTheme.onAccent,
                                ),
                              )
                            : Icon(
                                hasInvite
                                    ? Icons.person_add_alt_1_rounded
                                    : Icons.bolt_rounded,
                              ),
                        label: Text(
                          hasInvite
                              ? (state.busy
                                  ? 'Joining…'
                                  : 'Join & chat with ${inviterName ?? 'them'}')
                              : 'One-click join',
                        ),
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          textStyle: GoogleFonts.syne(
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        hasInvite
                            ? 'Creates a unique handle + password, then opens a chat with your inviter.'
                            : 'Creates a unique account instantly — best for testing from another device.',
                        textAlign: TextAlign.center,
                        style: GoogleFonts.ibmPlexSans(
                          color: PrivetTheme.mist,
                          fontSize: 12,
                        ),
                      ),

                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 22),
                        child: Row(
                          children: [
                            Expanded(child: Divider(color: PrivetTheme.line)),
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 12),
                              child: Text(
                                'or',
                                style: GoogleFonts.ibmPlexSans(
                                  color: PrivetTheme.mist,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                            Expanded(child: Divider(color: PrivetTheme.line)),
                          ],
                        ),
                      ),

                      SegmentedButton<bool>(
                        segments: const [
                          ButtonSegment(value: false, label: Text('Sign in')),
                          ButtonSegment(value: true, label: Text('Create account')),
                        ],
                        selected: {_registerMode},
                        onSelectionChanged: (s) {
                          setState(() {
                            _registerMode = s.first;
                          });
                          widget.state.setError(null);
                        },
                        style: ButtonStyle(
                          foregroundColor: WidgetStateProperty.resolveWith((states) {
                            if (states.contains(WidgetState.selected)) {
                              return PrivetTheme.onAccent;
                            }
                            return PrivetTheme.paper;
                          }),
                          backgroundColor: WidgetStateProperty.resolveWith((states) {
                            if (states.contains(WidgetState.selected)) {
                              return PrivetTheme.signal;
                            }
                            return PrivetTheme.panelElevated;
                          }),
                        ),
                      ),
                      const SizedBox(height: 18),

                      TextField(
                        controller: _handle,
                        autofillHints: _registerMode
                            ? const [AutofillHints.newUsername]
                            : const [AutofillHints.username],
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z0-9_]')),
                          LengthLimitingTextInputFormatter(24),
                        ],
                        decoration: InputDecoration(
                          labelText: 'Handle',
                          prefixIcon: const Icon(Icons.alternate_email_rounded),
                          helperText: _registerMode
                              ? (_handleHint ?? '3–24 chars · a-z, 0-9, _')
                              : null,
                          helperStyle: TextStyle(
                            color: _handleHint?.contains('available') == true
                                ? PrivetTheme.signal
                                : PrivetTheme.mist,
                            fontSize: 12,
                          ),
                        ),
                        textInputAction: TextInputAction.next,
                        onChanged: _registerMode ? _onHandleChanged : null,
                      ),
                      if (_registerMode) ...[
                        const SizedBox(height: 12),
                        TextField(
                          controller: _displayName,
                          autofillHints: const [AutofillHints.name],
                          decoration: const InputDecoration(
                            labelText: 'Display name (optional)',
                            prefixIcon: Icon(Icons.badge_outlined),
                            helperText: 'Defaults to your handle',
                          ),
                          textInputAction: TextInputAction.next,
                        ),
                      ],
                      const SizedBox(height: 12),
                      TextField(
                        controller: _password,
                        obscureText: _obscure,
                        autofillHints: _registerMode
                            ? const [AutofillHints.newPassword]
                            : const [AutofillHints.password],
                        decoration: InputDecoration(
                          labelText: 'Password',
                          prefixIcon: const Icon(Icons.lock_outline_rounded),
                          helperText: _registerMode ? 'At least 8 characters' : null,
                          suffixIcon: IconButton(
                            onPressed: () => setState(() => _obscure = !_obscure),
                            icon: Icon(
                              _obscure
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                            ),
                          ),
                        ),
                        textInputAction:
                            _registerMode ? TextInputAction.next : TextInputAction.done,
                        onSubmitted: (_) {
                          if (!_registerMode) _submit();
                        },
                      ),
                      if (_registerMode) ...[
                        const SizedBox(height: 12),
                        TextField(
                          controller: _confirm,
                          obscureText: _obscure,
                          autofillHints: const [AutofillHints.newPassword],
                          decoration: InputDecoration(
                            labelText: 'Confirm password',
                            prefixIcon: const Icon(Icons.lock_person_outlined),
                            suffixIcon: IconButton(
                              onPressed: () => setState(() => _obscure = !_obscure),
                              icon: Icon(
                                _obscure
                                    ? Icons.visibility_outlined
                                    : Icons.visibility_off_outlined,
                              ),
                            ),
                          ),
                          onSubmitted: (_) => _submit(),
                        ),
                      ],

                      if (state.error != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          state.error!,
                          style: TextStyle(color: PrivetTheme.danger),
                        ),
                      ],
                      const SizedBox(height: 20),
                      ElevatedButton(
                        onPressed: state.busy ? null : _submit,
                        child: state.busy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : Text(_registerMode ? 'Create account' : 'Sign in'),
                      ),
                      const SizedBox(height: 18),
                      Text(
                        'Demo accounts: alex / privet · mira / privet · jon / privet',
                        textAlign: TextAlign.center,
                        style: GoogleFonts.ibmPlexSans(
                          color: PrivetTheme.mist,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _onHandleChanged(String value) {
    _handleDebounce?.cancel();
    final handle = value.trim().toLowerCase();
    if (handle.length < 3) {
      setState(() => _handleHint = '3–24 chars · a-z, 0-9, _');
      return;
    }
    _handleDebounce = Timer(const Duration(milliseconds: 350), () async {
      try {
        final data = await widget.state.api.checkHandle(handle);
        if (!mounted) return;
        setState(() {
          _handleHint = data['available'] == true
              ? '@$handle is available'
              : (data['reason'] as String? ?? 'Unavailable');
        });
      } catch (_) {
        if (!mounted) return;
        setState(() => _handleHint = null);
      }
    });
  }

  Future<void> _submit() async {
    final handle = _handle.text.trim();
    final password = _password.text;
    if (handle.isEmpty || password.isEmpty) {
      widget.state.setError('Handle and password are required');
      return;
    }
    if (_registerMode) {
      if (password.length < 8) {
        widget.state.setError('Password must be at least 8 characters');
        return;
      }
      if (password != _confirm.text) {
        widget.state.setError('Passwords do not match');
        return;
      }
      await widget.state.register(
        handle: handle,
        password: password,
        displayName: _displayName.text,
      );
    } else {
      await widget.state.login(handle, password);
    }
  }

  Future<void> _quickJoin() async {
    await widget.state.quickJoin(inviteHandle: widget.state.pendingInviteHandle);
  }
}
