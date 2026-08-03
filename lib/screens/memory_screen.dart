import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/models.dart';

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

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _onSearch(String q) async {
    final res = await widget.shiyi.searchAllMemories(q);
    if (!mounted) return;
    setState(() {
      _searching = q.trim().isNotEmpty;
      _results = res;
    });
  }

  @override
  Widget build(BuildContext context) {
    final shiyi = widget.shiyi;
    return ListenableBuilder(
      listenable: shiyi,
      builder: (context, _) {
        final display = _searching ? _results : shiyi.memories;
        return Scaffold(
          appBar: AppBar(title: const Text('长期记忆')),
          body: Column(children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: TextField(
                controller: _searchCtrl,
                onChanged: (q) => _onSearch(q),
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: '搜索记忆（全文检索）',
                  border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(24))),
                  isDense: true,
                ),
              ),
            ),
            Expanded(
              child: display.isEmpty
                  ? const Center(child: Text('还没有记忆\n长按对话消息可保存', textAlign: TextAlign.center))
                  : ListView.builder(
                      itemCount: display.length,
                      itemBuilder: (context, i) {
                        final m = display[i];
                        return ListTile(
                          leading: const Icon(Icons.bookmark_outlined),
                          title: Text(m.content, maxLines: 3, overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                              '${m.source == 'assistant' ? 'Agent 记录' : '手动'} · ${_fmt(m.createdAt)}'),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () async {
                              await shiyi.deleteMemory(m.id);
                              if (_searching) await _onSearch(_searchCtrl.text);
                            },
                          ),
                          onTap: () => _detail(m.content),
                        );
                      },
                    ),
            ),
          ]),
        );
      },
    );
  }

  void _detail(String content) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('记忆内容'),
        content: SelectableText(content),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
        ],
      ),
    );
  }

  String _fmt(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.month}月${d.day}日 ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }
}