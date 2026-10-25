import 'package:flutter/material.dart';

import '../app/app_model.dart';
import '../playback/playback_lifecycle.dart';
import 'channels/channel_page.dart';
import 'tools/tools_page.dart';
import 'video/video_feed_page.dart';

/// Top-level shell: three tabs, one IndexedStack.
///
/// Why IndexedStack and not TabBarView: the video tab must keep its scroll
/// position and its loaded page window when the user hops to 功能 and back.
/// TabBarView rebuilds off-screen children, which throws away the pager cursor
/// and forces a re-read of the index on every switch.
///
/// The player itself is *not* kept alive: switching away from the video tab
/// goes through [PlaybackLifecycleBinder.handleTabChanged], which pauses and
/// disposes the decoder.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with SingleTickerProviderStateMixin {
  late final TabController _tabs =
      TabController(length: 3, vsync: this)..addListener(_onTabSettled);

  int _index = 0;

  static const List<String> _titles = <String>['频道', '视频', '功能'];

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
    // Leaving the video tab: free the decoder instead of letting audio keep
    // running behind another page.
    if (next != 1) {
      AppScope.read(context).services.binder.handleTabChanged(next);
    }
  }

  @override
  Widget build(BuildContext context) {
    final model = AppScope.of(context).model;
    final services = AppScope.of(context).services;

    return Scaffold(
      appBar: AppBar(
        title: Text(_titles[_index]),
        actions: _actionsFor(context, model),
        bottom: TabBar(
          controller: _tabs,
          onTap: _applyIndex,
          tabs: const <Widget>[
            Tab(icon: Icon(Icons.forum_outlined), text: '频道'),
            Tab(icon: Icon(Icons.play_circle_outline), text: '视频'),
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
