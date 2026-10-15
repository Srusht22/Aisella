import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/l10n/l10n.dart';
import '../design_system/components/feedback.dart';
import '../design_system/theme/theme_ext.dart';
import '../design_system/tokens/tokens.g.dart';
import '../features/auth/application/auth_controller.dart';
import '../features/store/application/workspace_controller.dart';

/// Shown while the session is restored and the workspace loads. Shows no
/// seller data, so nothing protected can flash before authorization is known.
class StartingScreen extends StatefulWidget {
  const StartingScreen({super.key});

  @override
  State<StartingScreen> createState() => _StartingScreenState();
}

class _StartingScreenState extends State<StartingScreen> {
  late final Timer _delay;
  bool _showProgress = false;

  @override
  void initState() {
    super.initState();
    // The spinner appears only if loading takes longer than 300 ms (P-LOAD).
    _delay = Timer(
      const Duration(milliseconds: 300),
      () => setState(() => _showProgress = true),
    );
  }

  @override
  void dispose() {
    _delay.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final l10n = context.l10n;
    return Scaffold(
      backgroundColor: p.bgCanvas,
      body: Center(
        child: Semantics(
          label: l10n.openingStore,
          liveRegion: true,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                l10n.appName.toLowerCase(),
                style: context.type.titleLarge.copyWith(
                  color: p.brandPrimary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: Space.s24),
              AnimatedOpacity(
                opacity: _showProgress ? 1 : 0,
                duration: const Duration(milliseconds: 200),
                child: SizedBox.square(
                  dimension: 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: p.brandPrimary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The workspace could not be loaded (offline, server error). The seller can
/// retry or sign out; nothing from the store is shown.
class WorkspaceUnavailableScreen extends ConsumerWidget {
  const WorkspaceUnavailableScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    return Scaffold(
      backgroundColor: context.palette.bgCanvas,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ErrorState(
                cause: '${l10n.workspaceErrorTitle}. ${l10n.errNetwork}',
                onRetry: () => ref.read(workspaceProvider.notifier).reload(),
              ),
            ),
            TextButton(
              onPressed: () =>
                  ref.read(authControllerProvider.notifier).signOut(),
              child: Text(l10n.menuSignOut),
            ),
            const SizedBox(height: Space.s16),
          ],
        ),
      ),
    );
  }
}
