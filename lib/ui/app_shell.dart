import 'package:flutter/material.dart';

import '../app/app_model.dart';
import '../playback/playback_lifecycle.dart';
import 'channels/channel_page.dart';
import 'tools/tools_page.dart';
import 'video/video_feed_page.dart';

/// Top-level shell: four tabs, one IndexedStack.
///
/// Why IndexedStack and not TabBarView: the video tab must keep its scroll
/// position and its loaded page window when the user hops to 功能 and back.
/// TabBarView rebuilds off-screen children, which throws away the pager cursor
/// and forces a re-read of the index on every switch.
///
/// The player itself is *not* kept alive: switching away from either video tab
/// goes through [PlaybackLifecycleBinder.handleTabChanged], which pauses and
/// disposes the decoder.
///
/// The 抖音 tab is the same feed page in `immersive` + `randomOrder` mode
/// rather than a second implementation: entering it hides the app bar and the
/// tab strip so the video owns the whole screen, and its back button returns to
/// 视频. Sharing one widget is what keeps "one decoder at a time" true.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with SingleTickerProviderStateMixin {
  late final TabController _tabs =
      TabController(length: 4, vsync: this)..addListener(_onTabSettled);

  int _index = 0;

  static const List<String> _titles = <String>['频道', '视频', '抖音', '功能'];

  /// Index of the full-screen tab. It hides the shell chrome entirely, so the
  /// screen is the video and nothing else.
  static const int _immersiveTab = 2;

  bool get _immersive => _index == _immersiveTab;

  @override
  void dispose() {
    _tabs.removeListener(_onTabSettled);
    _tabs.dispose();
    super.dispose();
  }

  void _onTabSettled() {
    if (_tabs.indexIsChanging) return;
    _applyIndex(_tabs.index);
  }

  void _applyIndex(int next) {
    if (next == _index) return;
    setState(() => _index = next);
    // Both video tabs own the decoder. Moving between them is handled by the
    // two pages themselves (the outgoing one releases before the incoming one
    // activates); leaving either for a non-playing tab frees it here.
    if (next != 1 && next != 2) {
      AppScope.read(context).services.binder.handleTabChanged(next);
    }
  }

  @override
  Widget build(BuildContext context) {
    final model = AppScope.of(context).model;
    final services = AppScope.of(context).services;

    return Scaffold(
      // Null app bar removes the tab strip with it: 抖音 is meant to fill the
      // screen, and a strip under a full-bleed video also breaks the immersive
      // framing the tab is for.
      appBar: _immersive
          ? null
          : AppBar(
              title: Text(_titles[_index]),
              actions: _actionsFor(context, model),
              bottom: TabBar(
                controller: _tabs,
                onTap: _applyIndex,
                tabs: const <Widget>[
                  Tab(icon: Icon(Icons.forum_outlined), text: '频道'),
                  Tab(icon: Icon(Icons.play_circle_outline), text: '视频'),
                  Tab(icon: Icon(Icons.smart_display_outlined), text: '抖音'),
                  Tab(icon: Icon(Icons.grid_view_outlined), text: '功能'),
                ],
              ),
            ),
      body: PlaybackLifecycleObserver(
        binder: services.binder,
        child: IndexedStack(
          index: _index,
          children: <Widget>[
            ChannelPage(
              onOpenVideos: (chat) {
                // Filter the feed to the tapped channel and move the user
                // there — a channel row that only changed a hidden filter would
                // look broken.
                model.setCategory(chat.id);
                _goToTab(1);
              },
            ),
            VideoFeedPage(
              active: _index == 1,
              onExit: () => _goToTab(0),
            ),
            VideoFeedPage(
              active: _index == _immersiveTab,
              randomOrder: true,
              immersive: true,
              // The back button is the only way out while the tab strip is
              // hidden, so it has to land somewhere useful rather than popping
              // the whole shell.
              onExit: () => _goToTab(1),
            ),
            const ToolsPage(),
          ],
        ),
      ),
    );
  }

  void _goToTab(int index) {
    if (_tabs.index != index) _tabs.animateTo(index);
    _applyIndex(index);
  }

  List<Widget> _actionsFor(BuildContext context, AppModel model) {
    if (_index != 1) return const <Widget>[];
    return <Widget>[
      IconButton(
        tooltip: model.searchOpen ? '关闭搜索' : '搜索视频',
        icon: Icon(model.searchOpen ? Icons.search_off : Icons.search),
        onPressed: model.toggleSearch,
      ),
    ];
  }
}
