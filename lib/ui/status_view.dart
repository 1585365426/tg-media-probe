/// The four states every screen in this app must be able to show (§6.4):
/// loading, empty, error-with-retry, and "content".
///
/// One implementation per state so a screen cannot quietly invent a fifth
/// wording, and so "no data" is never rendered as an empty list with no
/// explanation.
library;

import 'package:flutter/material.dart';

import 'app_theme.dart';

enum StatusKind { loading, empty, error, permission, signedOut }

class StatusView extends StatelessWidget {
  const StatusView({
    super.key,
    required this.kind,
    required this.title,
    this.message,
    this.actionLabel,
    this.onAction,
    this.progress,
    this.padding = const EdgeInsets.all(AppTheme.pagePadding),
  });

  const StatusView.loading({
    super.key,
    this.title = '正在加载',
    this.message,
    this.progress,
    this.padding = const EdgeInsets.all(AppTheme.pagePadding),
  })  : kind = StatusKind.loading,
        actionLabel = null,
        onAction = null;

  const StatusView.empty({
    super.key,
    required this.title,
    this.message,
    this.actionLabel,
    this.onAction,
    this.padding = const EdgeInsets.all(AppTheme.pagePadding),
  })  : kind = StatusKind.empty,
        progress = null;

  const StatusView.error({
    super.key,
    required this.title,
    this.message,
    this.actionLabel = '重试',
    this.onAction,
    this.padding = const EdgeInsets.all(AppTheme.pagePadding),
  })  : kind = StatusKind.error,
        progress = null;

  final StatusKind kind;
  final String title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;

  /// 0..1 for [StatusKind.loading], or null for an indeterminate indicator.
  final double? progress;
  final EdgeInsets padding;

  IconData get _icon => switch (kind) {
        StatusKind.loading => Icons.hourglass_empty,
        StatusKind.empty => Icons.inbox_outlined,
        StatusKind.error => Icons.error_outline,
        StatusKind.permission => Icons.lock_outline,
        StatusKind.signedOut => Icons.person_off_outlined,
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: Padding(
        padding: padding,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            if (kind == StatusKind.loading)
              SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  value: progress,
                ),
              )
            else
              Icon(_icon, size: 32, color: scheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleSmall,
            ),
            if (message != null && message!.isNotEmpty) ...<Widget>[
              const SizedBox(height: 6),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
            if (onAction != null && actionLabel != null) ...<Widget>[
              const SizedBox(height: 16),
              FilledButton.tonal(
                onPressed: onAction,
                child: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Grouped card used by the settings screen: small caps title, rows, spacing
/// between groups larger than the spacing inside one (§6.1 截图 2 的取法).
class SettingsSection extends StatelessWidget {
  const SettingsSection({
    super.key,
    required this.title,
    required this.children,
    this.footnote,
  });

  final String title;
  final List<Widget> children;
  final String? footnote;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(left: 28, bottom: 8),
            child: Text(
              title,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                letterSpacing: 0.4,
              ),
            ),
          ),
          Container(
            margin: const EdgeInsets.symmetric(horizontal: AppTheme.pagePadding),
            decoration: AppTheme.card(context),
            clipBehavior: Clip.antiAlias,
            child: Column(children: children),
          ),
          if (footnote != null)
            Padding(
              padding: const EdgeInsets.only(left: 28, right: 28, top: 8),
              child: Text(
                footnote!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A card row. Trailing chevron only when the row actually navigates or opens a
/// picker — a chevron on a row that does nothing is a lie about affordance.
class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
    this.showChevron = false,
    this.enabled = true,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool showChevron;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = enabled ? scheme.onSurface : scheme.onSurface.withValues(alpha: 0.4);
    return InkWell(
      onTap: enabled ? onTap : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppTheme.pagePadding,
          vertical: 13,
        ),
        child: Row(
          children: <Widget>[
            if (leading != null) ...<Widget>[
              IconTheme(
                data: IconThemeData(size: 20, color: color),
                child: leading!,
              ),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(title, style: theme.textTheme.bodyMedium?.copyWith(color: color)),
                  if (subtitle != null && subtitle!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        subtitle!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant
                              .withValues(alpha: enabled ? 1 : 0.5),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (trailing != null) ...<Widget>[
              const SizedBox(width: 8),
              trailing!,
            ],
            if (showChevron)
              Icon(Icons.chevron_right, size: 20, color: scheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

/// Thin separator used between rows inside a [SettingsSection].
class SettingsDivider extends StatelessWidget {
  const SettingsDivider({super.key});

  @override
  Widget build(BuildContext context) => const Divider(height: 1, indent: 16, endIndent: 16);
}
