import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'brand_mark.dart';

/// Desktop-only frame for Cwhale's workspace. The phone navigation remains
/// owned by ChatScreen and is not scaled into this layout.
class CwhaleDesktopWorkspace extends StatelessWidget {
  const CwhaleDesktopWorkspace({
    required this.conversationSidebar,
    required this.titleBar,
    required this.content,
    required this.onNotifications,
    required this.onAccount,
    required this.onSettings,
    required this.accountLabel,
    this.inspector,
    super.key,
  });

  static const railWidth = 68.0;

  final Widget conversationSidebar;
  final Widget titleBar;
  final Widget content;
  final Widget? inspector;
  final VoidCallback onNotifications;
  final VoidCallback onAccount;
  final VoidCallback onSettings;
  final String accountLabel;

  @override
  Widget build(BuildContext context) {
    final dark = CwhaleTheme.isDark;
    final railSurface = dark
        ? const Color(0xff17181b)
        : const Color(0xffedf0f4);
    final separator = dark ? const Color(0xff303136) : const Color(0xffd8dde5);

    return Row(
      children: [
        SizedBox(
          width: railWidth,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: railSurface,
              border: Border(right: BorderSide(color: separator)),
            ),
            child: SafeArea(
              child: Column(
                children: [
                  const SizedBox(height: 12),
                  const CwhaleBrandMark(size: 40, cornerRadius: 13),
                  const SizedBox(height: 20),
                  _RailButton(
                    tooltip: '当前区域：对话',
                    icon: Icons.chat_bubble_outline_rounded,
                    selected: true,
                    onPressed: () {},
                  ),
                  const SizedBox(height: 9),
                  _RailButton(
                    tooltip: '通知与活动',
                    icon: Icons.notifications_none_rounded,
                    onPressed: onNotifications,
                  ),
                  const Spacer(),
                  Tooltip(
                    message: accountLabel,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(15),
                      onTap: onAccount,
                      child: Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: CwhaleTheme.surface,
                          borderRadius: BorderRadius.circular(15),
                          border: Border.all(color: separator),
                        ),
                        child: Icon(
                          Icons.person_outline_rounded,
                          color: CwhaleTheme.muted,
                          size: 20,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 9),
                  _RailButton(
                    tooltip: '设置',
                    icon: Icons.settings_outlined,
                    onPressed: onSettings,
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          ),
        ),
        conversationSidebar,
        Expanded(
          child: Column(
            children: [
              titleBar,
              Expanded(child: content),
            ],
          ),
        ),
        if (inspector != null) inspector!,
      ],
    );
  }
}

class _RailButton extends StatelessWidget {
  const _RailButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.selected = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final foreground = selected ? CwhaleTheme.accent : CwhaleTheme.muted;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: selected ? CwhaleTheme.selectedSurface : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onPressed,
          child: SizedBox(
            width: 42,
            height: 42,
            child: Icon(icon, color: foreground, size: 20),
          ),
        ),
      ),
    );
  }
}
