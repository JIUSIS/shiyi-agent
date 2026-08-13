import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/models.dart';
import '../widgets/ios_style.dart';
import '../widgets/traffic_lights_button.dart';

class MemoryScreen extends StatefulWidget {
  final ShiyiState shiyi;
  const MemoryScreen({super.key, required this.shiyi});

  @override
  State<MemoryScreen> createState() => _MemoryScreenState();
}

class _MemoryScreenState extends State<MemoryScreen> {
  final TextEditingController _searchCtrl = TextEditingController();
  List<MemoryEntry> _results = [];
  bool _searching = false;
  bool _selectionMode = false;
  final Set<int> _selectedIds = {};

  /// 搜索防抖计时器（每键一次全库检索太浪费）。
  Timer? _searchDebounce;

  /// 请求序号：防旧请求晚到覆盖新结果（竞态）。
  int _searchGeneration = 0;

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onSearch(String q) {
    _searchDebounce?.cancel();
    final query = q.trim();
    _searchDebounce = Timer(const Duration(milliseconds: 250), () {
      _runSearch(query);
    });
  }

  /// 立即执行一次搜索（防抖回调与删除后刷新共用）。
  Future<void> _runSearch(String query) async {
    final gen = ++_searchGeneration;
    final res = await widget.shiyi.searchAllMemories(query);
    if (!mounted || gen != _searchGeneration) return; // 已有更新的搜索
    setState(() {
      _searching = query.isNotEmpty;
      _results = res;
    });
  }

  void _toggleSelectionMode() {
    FocusScope.of(context).unfocus();
    setState(() {
      _selectionMode = !_selectionMode;
      _selectedIds.clear();
    });
  }

  void _toggleSelected(MemoryEntry m) {
    setState(() {
      if (!_selectedIds.add(m.id)) _selectedIds.remove(m.id);
    });
  }

  Future<void> _deleteMemory(MemoryEntry m) async {
    final ok = await _confirmDelete('删除这条记忆吗？');
    if (ok != true || !mounted) return;
    await widget.shiyi.deleteMemory(m.id);
    if (_searching && mounted) await _runSearch(_searchCtrl.text.trim());
  }

  Future<void> _deleteSelected() async {
    if (_selectedIds.isEmpty) return;
    final ok = await _confirmDelete('删除选中的 ${_selectedIds.length} 条记忆吗？');
    if (ok != true || !mounted) return;
    for (final id in List<int>.from(_selectedIds)) {
      await widget.shiyi.deleteMemory(id);
    }
    if (!mounted) return;
    setState(() {
      _selectionMode = false;
      _selectedIds.clear();
    });
    if (_searching && mounted) await _runSearch(_searchCtrl.text.trim());
  }

  Future<bool?> _confirmDelete(String message) {
    return showIosFadeDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('删除记忆'),
        content: Text(message),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  Future<void> _newMemory() async {
    final ctrl = TextEditingController();
    FocusScope.of(context).unfocus();
    final content = await showIosFadeDialog<String>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('新建记忆'),
        content: CupertinoTextField(
          controller: ctrl,
          autofocus: true,
          maxLines: 4,
          placeholder: '输入要长期记住的内容',
          padding: const EdgeInsets.all(10),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (content == null || content.isEmpty || !mounted) return;
    await widget.shiyi.addMemoryManual(content);
  }

  @override
  Widget build(BuildContext context) {
    final shiyi = widget.shiyi;
    final theme = Theme.of(context);
    return CupertinoTheme(
      data: CupertinoThemeData(brightness: theme.brightness),
      child: ListenableBuilder(
        listenable: shiyi,
        builder: (context, _) {
          final display = _searching ? _results : shiyi.memories;
          final selectedCount = _selectedIds.length;
          return Scaffold(
            backgroundColor: iosGroupedBackground(context),
            appBar: AppBar(
              leadingWidth: 72,
              leading: Padding(
                padding: const EdgeInsets.only(left: 12),
                child: TrafficLightsButton(
                  busy: shiyi.isBusy,
                  tooltip: '新建记忆',
                  onTap: _newMemory,
                ),
              ),
              toolbarHeight: 64,
              centerTitle: true,
              backgroundColor: theme.scaffoldBackgroundColor,
              surfaceTintColor: Colors.transparent,
              elevation: 0,
              scrolledUnderElevation: 0,
              clipBehavior: Clip.none,
              title: const Text(
                '长期记忆',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
              ),
              actions: [
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: CupertinoButton(
                    padding: EdgeInsets.zero,
                    onPressed: _toggleSelectionMode,
                    child: Text(
                      _selectionMode ? '完成' : '多选',
                      style: const TextStyle(
                        fontSize: 16,
                        color: CupertinoColors.activeBlue,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            body: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
                  child: CupertinoSearchTextField(
                    controller: _searchCtrl,
                    placeholder: '搜索记忆（全文检索）',
                    onChanged: _onSearch,
                  ),
                ),
                Expanded(
                  child: display.isEmpty
                      ? Center(
                          child: Text(
                            _searching ? '没有找到匹配的记忆' : '还没有记忆\n长按对话消息可保存',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 15,
                              color: CupertinoColors.secondaryLabel,
                            ),
                          ),
                        )
                      : ListView(
                          padding: const EdgeInsets.only(top: 4, bottom: 16),
                          children: [
                            CupertinoListSection.insetGrouped(
                              margin: iosSectionMargin,
                              decoration: iosSectionDecoration(context),
                              children: [
                                for (final m in display) _buildTile(m),
                              ],
                            ),
                          ],
                        ),
                ),
              ],
            ),
            bottomNavigationBar: _selectionMode && display.isNotEmpty
                ? Container(
                    decoration: BoxDecoration(
                      color: iosGroupedBackground(context),
                      border: Border(
                        top: BorderSide(
                          color: CupertinoColors.separator,
                          width: 0.5,
                        ),
                      ),
                    ),
                    child: SafeArea(
                      top: false,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                        child: CupertinoButton(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          borderRadius: const BorderRadius.all(
                            Radius.circular(12),
                          ),
                          color: CupertinoColors.systemRed,
                          disabledColor: CupertinoColors.systemGrey5,
                          onPressed: selectedCount == 0
                              ? null
                              : _deleteSelected,
                          child: Text(
                            selectedCount == 0 ? '选择记忆' : '删除（$selectedCount）',
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                  )
                : null,
          );
        },
      ),
    );
  }

  Widget _buildTile(MemoryEntry m) {
    final selected = _selectedIds.contains(m.id);
    return CupertinoListTile(
      padding: const EdgeInsetsDirectional.fromSTEB(16, 7, 8, 7),
      leadingSize: 26,
      leadingToTitle: 10,
      leading: Icon(
        _selectionMode
            ? (selected
                  ? CupertinoIcons.checkmark_circle_fill
                  : CupertinoIcons.circle)
            : CupertinoIcons.bookmark_fill,
        color: _selectionMode
            ? (selected
                  ? CupertinoColors.activeBlue
                  : CupertinoColors.systemGrey3)
            : CupertinoColors.activeBlue,
      ),
      title: Text(
        m.content,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontSize: 14,
          height: 1.35,
          fontWeight: FontWeight.w500,
        ),
      ),
      subtitle: Text(
        '${m.source == 'assistant' ? 'Agent 记录' : '手动'} · ${_fmt(m.createdAt)}',
        style: const TextStyle(fontSize: 12, height: 1.2),
      ),
      trailing: _selectionMode
          ? null
          : CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: () => _deleteMemory(m),
              child: const Icon(
                CupertinoIcons.trash,
                color: CupertinoColors.systemRed,
              ),
            ),
      onTap: () => _selectionMode ? _toggleSelected(m) : _detail(m.content),
    );
  }

  void _detail(String content) {
    showIosFadeDialog<void>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('记忆内容'),
        content: SingleChildScrollView(child: SelectableText(content)),
        actions: [
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.pop(ctx),
            child: const Text('好'),
          ),
        ],
      ),
    );
  }

  String _fmt(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.month}月${d.day}日 ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }
}
