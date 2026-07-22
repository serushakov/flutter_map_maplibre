import 'package:flutter/material.dart';
import 'package:flutter_map_maplibre/flutter_map_maplibre.dart';

void main() => runApp(const ProbeApp());

class ProbeApp extends StatelessWidget {
  const ProbeApp({super.key});

  @override
  Widget build(BuildContext context) => const MaterialApp(home: ProbePage());
}

class ProbePage extends StatefulWidget {
  const ProbePage({super.key});

  @override
  State<ProbePage> createState() => _ProbePageState();
}

class _ProbePageState extends State<ProbePage> {
  ProbeResult? _result;

  @override
  void initState() {
    super.initState();
    // Auto-run so the probe can be driven headlessly (simctl, CI) without a tap.
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    final result = await TextureProbe().run(width: 512, height: 512);
    if (!mounted) return;
    setState(() => _result = result);
    debugPrint('probe: $result');
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return Scaffold(
      appBar: AppBar(title: const Text('Texture probe')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FilledButton(onPressed: _run, child: const Text('Run probe')),
            const SizedBox(height: 16),
            if (result != null) ...[
              Text(result.ok ? 'OK' : 'FAILED: ${result.error}'),
              const SizedBox(height: 8),
              // A red square here means native GPU output reached Flutter's
              // compositor. Anything else (black, blank) means it did not.
              if (result.textureId != null)
                SizedBox(
                  height: 200,
                  child: Texture(textureId: result.textureId!),
                ),
              const SizedBox(height: 16),
              Expanded(
                child: SingleChildScrollView(
                  child: Text(
                    result.diagnostics.entries
                        .map((e) => '${e.key}: ${e.value}')
                        .join('\n'),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
