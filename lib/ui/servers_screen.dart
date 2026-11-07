import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/engine.dart';
import '../core/server.dart';
import '../core/vpn_controller.dart';
import 'flag_badge.dart';
import 'strings.dart';
import 'style.dart';
import 'widgets.dart';

enum _ServerFilter { all, responsive, noReply, untested }

/// Every server with manual ping test and one-tap connect to a specific server.
class ServersScreen extends StatefulWidget {
  const ServersScreen({super.key, required this.controller, this.embedded = false, this.onConnect});

  final VpnController controller;

  /// Shown as a bottom-navigation tab (no back button; connecting calls [onConnect] instead of popping).
  final bool embedded;
  final VoidCallback? onConnect;

  @override
  State<ServersScreen> createState() => _ServersScreenState();
}

class _ServersScreenState extends State<ServersScreen> {
  // Every listed server is tested; results appear live as each one finishes.
  static const _maxPing = 100000;
  String _query = '';
  bool _byPing = false;
  _ServerFilter _filter = _ServerFilter.all;

  List<Server> _matching() {
    final c = widget.controller;
    final q = _query.trim().toLowerCase();
    final list = c.servers
        .where((s) =>
            q.isEmpty ||
            s.displayName.contains(q) ||
            serverTitle(s).toLowerCase().contains(q) ||
            s.countryCode.toLowerCase().contains(q) ||
            s.protocolLabel.toLowerCase().contains(q))
        .toList();
    return list;
  }

  List<Server> _visible() {
    final c = widget.controller;
    final list = _matching();
    list.removeWhere((s) {
      final delay = c.delays[s.uri];
      return switch (_filter) {
        _ServerFilter.all => false,
        _ServerFilter.responsive => delay == null || delay <= 0,
        _ServerFilter.noReply => delay == null || delay > 0,
        _ServerFilter.untested => delay != null,
      };
    });
    if (_byPing) {
      int key(Server s) {
        final d = c.delays[s.uri];
        return d == null ? 1 << 30 : (d <= 0 ? 1 << 29 : d);
      }

      list.sort((a, b) => key(a).compareTo(key(b)));
    }
    return list;
  }

  Widget _filterChip(String label, int count, _ServerFilter filter) {
    final selected = _filter == filter;
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 8),
      child: ChoiceChip(
        label: Text('$label $count'),
        selected: selected,
        onSelected: (_) => setState(() => _filter = filter),
        selectedColor: Palette.accent.withValues(alpha: 0.18),
        backgroundColor: Palette.surface,
        side: BorderSide(color: selected ? Palette.accent : Palette.border),
        labelStyle: TextStyle(
          color: selected ? Palette.accentText : Palette.muted,
          fontSize: 12,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Palette.pillRadius)),
        showCheckmark: false,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final matching = _matching();
        final list = _visible();
        final responsive = matching.where((s) => (c.delays[s.uri] ?? 0) > 0).length;
        final noReply = matching.where((s) => c.delays[s.uri] != null && c.delays[s.uri]! <= 0).length;
        final untested = matching.where((s) => !c.delays.containsKey(s.uri)).length;
        final tested = responsive;
        return PageShell(
          title: tr('سرورها', 'Servers'),
          subtitle: '${tr('${list.length} سرور · $tested پاسخ داده', '${list.length} servers · $tested responded')} · '
              '${serversUpdatedAgo(c.updatedAt)}',
          showBack: !widget.embedded,
          actions: [
            IconButton(
              tooltip: tr('مرتب‌سازی بر اساس پینگ', 'Sort by ping'),
              onPressed: () => setState(() => _byPing = !_byPing),
              icon: Icon(Icons.sort_rounded, color: _byPing ? Palette.accent : Palette.muted),
            ),
          ],
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Row(children: [
                Expanded(
                  child: TextField(
                    onChanged: (v) => setState(() => _query = v),
                    style: TextStyle(color: Palette.text),
                    decoration: InputDecoration(
                      hintText: tr('جستجو: کشور، پروتکل…', 'Search: country, protocol…'),
                      hintStyle: TextStyle(color: Palette.muted),
                      prefixIcon: Icon(Icons.search_rounded, color: Palette.muted),
                      filled: true,
                      fillColor: Palette.surface,
                      contentPadding: const EdgeInsets.symmetric(vertical: 12),
                      enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(Palette.pillRadius), borderSide: Palette.cardSide),
                      focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: Palette.accent)),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton.icon(
                  onPressed: c.pinging || c.state == VpnState.connecting
                      ? null
                      : () {
                          c.pingServers(list.take(_maxPing).toList());
                          setState(() => _byPing = true);
                        },
                  style: FilledButton.styleFrom(
                    backgroundColor: Palette.accent,
                    foregroundColor: Palette.bg,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  icon: c.pinging
                      ? SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Palette.muted))
                      : const Icon(Icons.network_ping_rounded, size: 18),
                  label: Text(c.pinging ? tr('در حال تست', 'Testing') : tr('تست پینگ', 'Ping test')),
                ),
              ]),
            ),
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(16, 4, 16, 6),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: [
                  _filterChip(tr('همه', 'All'), matching.length, _ServerFilter.all),
                  _filterChip(tr('پاسخ‌دار', 'Responding'), responsive, _ServerFilter.responsive),
                  _filterChip(tr('بی‌پاسخ', 'No reply'), noReply, _ServerFilter.noReply),
                  _filterChip(tr('تست‌نشده', 'Untested'), untested, _ServerFilter.untested),
                ]),
              ),
            ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                itemCount: list.length,
                itemBuilder: (context, i) => _Entrance(
                  index: i,
                  child: _ServerTile(
                    server: list[i],
                    delay: c.delays[list[i].uri],
                    active: c.current?.uri == list[i].uri,
                    favorite: c.isFavorite(list[i]),
                    onStar: () => c.toggleFavorite(list[i]),
                    onTap: () {
                      if (widget.embedded) {
                        widget.onConnect?.call();
                      } else {
                        Navigator.of(context).pop();
                      }
                      c.connectTo(list[i]);
                    },
                  ),
                ),
              ),
            ),
          ]),
        );
      },
    );
  }
}

class _Entrance extends StatelessWidget {
  const _Entrance({required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (Palette.reduceMotion) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: 240 + math.min(index, 12) * 30),
      curve: Curves.easeOutCubic,
      builder: (context, v, child) => Opacity(opacity: v, child: Transform.translate(offset: Offset(0, 14 * (1 - v)), child: child)),
      child: child,
    );
  }
}

class _ServerTile extends StatelessWidget {
  const _ServerTile({
    required this.server,
    required this.delay,
    required this.active,
    required this.favorite,
    required this.onStar,
    required this.onTap,
  });

  final Server server;
  final int? delay;
  final bool active, favorite;
  final VoidCallback onTap, onStar;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: AppCard(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        borderColor: active ? Palette.amber : null,
        onTap: onTap,
        child: Row(children: [
          FlagBadge(code: server.countryCode, size: 38),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(serverTitle(server),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Palette.text)),
              const SizedBox(height: 4),
              Row(children: [
                ProtocolTag(server.protocolLabel),
                if (active) ...[
                  const SizedBox(width: 8),
                  Text(tr('متصل', 'Connected'), style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: Palette.amber)),
                ],
              ]),
            ]),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: favorite ? tr('حذف از علاقه‌مندی‌ها', 'Remove from favorites') : tr('افزودن به علاقه‌مندی‌ها', 'Add to favorites'),
            onPressed: onStar,
            icon: Icon(
              favorite ? Icons.star_rounded : Icons.star_border_rounded,
              color: favorite ? Palette.connecting : Palette.muted,
            ),
          ),
          const SizedBox(width: 4),
          DelayPill(ms: delay),
        ]),
      ),
    );
  }
}
