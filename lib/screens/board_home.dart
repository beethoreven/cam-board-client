import 'package:cam_board_core/cam_board_core.dart';
import 'package:flutter/material.dart';

import '../board_controller.dart';

/// 看板端的畫面：沒註冊時輸入名字，註冊後顯示等候中。
class BoardHome extends StatelessWidget {
  const BoardHome({super.key, required this.controller});

  final BoardController controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('看板端')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ListenableBuilder(
            listenable: controller,
            builder: (context, _) => switch (controller.state) {
              BoardState.unregistered => _RegisterForm(controller: controller),
              BoardState.waiting => _Registered(controller: controller),
              BoardState.showing => _Showing(controller: controller),
            },
          ),
        ),
      ),
    );
  }
}

class _RegisterForm extends StatefulWidget {
  const _RegisterForm({required this.controller});

  final BoardController controller;

  @override
  State<_RegisterForm> createState() => _RegisterFormState();
}

class _RegisterFormState extends State<_RegisterForm> {
  final _name = TextEditingController();

  @override
  void initState() {
    super.initState();
    widget.controller.loadSavedName().then((saved) {
      if (mounted && saved != null && _name.text.isEmpty) _name.text = saved;
    });
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() => widget.controller.register(_name.text);

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _name,
          enabled: !controller.busy,
          decoration: InputDecoration(
            labelText: '看板名稱',
            border: const OutlineInputBorder(),
            errorText: controller.error,
          ),
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submit(),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: controller.busy ? null : _submit,
          child: const Text('註冊'),
        ),
      ],
    );
  }
}

class _Registered extends StatelessWidget {
  const _Registered({required this.controller});

  final BoardController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    final address = controller.address;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          controller.boardName ?? '',
          style: theme.headlineMedium,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text('等候中', style: theme.titleMedium, textAlign: TextAlign.center),
        const SizedBox(height: 32),
        Text(
          address == null
              ? '找不到區域網路位址，請確認手機已經連上 Wi-Fi 或開啟熱點'
              : '鄉民端找不到這個看板時，請手動輸入：',
          textAlign: TextAlign.center,
        ),
        if (address != null) ...[
          const SizedBox(height: 8),
          SelectableText(
            address,
            style: theme.headlineSmall,
            textAlign: TextAlign.center,
          ),
        ],
        const Spacer(),
        OutlinedButton(
          onPressed: controller.busy ? null : controller.unregister,
          child: const Text('撤銷註冊'),
        ),
      ],
    );
  }
}

/// 有鄉民端正在看：顯示鏡頭預覽、人數，以及鏡頭控制。
class _Showing extends StatelessWidget {
  const _Showing({required this.controller});

  final BoardController controller;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '${controller.viewerCount} 個鄉民端正在看',
          style: Theme.of(context).textTheme.titleMedium,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 12),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) => GestureDetector(
              key: const Key('preview'),
              onScaleStart: (_) => controller.pinchStarted(),
              onScaleUpdate: (details) {
                // 單指拖曳也會觸發這個手勢，只有兩指以上才算縮放。
                if (details.pointerCount >= 2) {
                  controller.pinchUpdated(details.scale);
                }
              },
              onTapUp: (details) => controller.focusAt(
                details.localPosition.dx / constraints.maxWidth,
                details.localPosition.dy / constraints.maxHeight,
              ),
              child: controller.camera.buildPreview(),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: controller.switchCamera,
                child: const Text('切換鏡頭'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                onPressed: controller.stopShowing,
                child: const Text('不給看了'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
