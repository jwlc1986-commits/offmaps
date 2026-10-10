import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mapsforge_flutter_renderer/offline_renderer.dart';

/// Envuelve un [Renderer] y mide cuánto tarda cada tile.
///
/// Funciona también en release (el profiler interno de mapsforge solo corre en debug).
/// Escribe en la consola líneas que empiezan por "OffMaps":
///   - OffMaps TILE lento ...  : un tile que superó [umbralMs]
///   - OffMaps TILES ...       : resumen por zoom cuando termina una ráfaga de tiles
class RendererMedido extends Renderer {
  final Renderer interno;

  /// Un tile que tarde más que esto (en milisegundos) se registra individualmente.
  final int umbralMs;

  RendererMedido(this.interno, {this.umbralMs = 400});

  final Map<int, _Acumulado> _porZoom = {};
  Timer? _temporizadorResumen;
  Stopwatch? _rafaga;
  int _enCurso = 0;
  int _maxSimultaneos = 0;

  @override
  void dispose() {
    _temporizadorResumen?.cancel();
    interno.dispose();
    super.dispose();
  }

  @override
  Future<JobResult> executeJob(JobRequest jobRequest) async {
    final tile = jobRequest.tile;
    if (_enCurso == 0) {
      _rafaga = Stopwatch()..start();
      _porZoom.clear();
      _maxSimultaneos = 0;
    }
    _enCurso++;
    if (_enCurso > _maxSimultaneos) _maxSimultaneos = _enCurso;
    final reloj = Stopwatch()..start();
    try {
      return await interno.executeJob(jobRequest);
    } finally {
      reloj.stop();
      _enCurso--;
      final ms = reloj.elapsedMilliseconds;
      final acum = _porZoom.putIfAbsent(tile.zoomLevel, () => _Acumulado());
      acum.n++;
      acum.totalMs += ms;
      if (ms > acum.maxMs) acum.maxMs = ms;
      if (ms >= umbralMs) {
        debugPrint('OffMaps TILE lento z=${tile.zoomLevel} '
            'x=${tile.tileX} y=${tile.tileY} $ms ms');
      }
      _temporizadorResumen?.cancel();
      _temporizadorResumen = Timer(const Duration(milliseconds: 1500), _imprimirResumen);
    }
  }

  void _imprimirResumen() {
    if (_enCurso > 0 || _porZoom.isEmpty) return;
    final total = _rafaga?.elapsedMilliseconds ?? 0;
    // La ráfaga dura hasta el último tile; se descuenta la espera del temporizador.
    final reales = total > 1500 ? total - 1500 : total;
    final zooms = _porZoom.keys.toList()..sort();
    for (final z in zooms) {
      final a = _porZoom[z]!;
      debugPrint('OffMaps TILES z=$z n=${a.n} promedio=${(a.totalMs / a.n).round()} ms '
          'max=${a.maxMs} ms ráfaga≈$reales ms simultáneos≤$_maxSimultaneos');
    }
    _porZoom.clear();
    _rafaga = null;
  }

  @override
  Future<JobResult> retrieveLabels(JobRequest jobRequest) => interno.retrieveLabels(jobRequest);

  @override
  String getRenderKey() => interno.getRenderKey();

  @override
  bool supportLabels() => interno.supportLabels();
}

class _Acumulado {
  int n = 0;
  int totalMs = 0;
  int maxMs = 0;
}
