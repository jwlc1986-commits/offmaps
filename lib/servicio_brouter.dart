import 'package:flutter/services.dart';
import 'package:mapsforge_flutter_core/model.dart';
import 'package:xml/xml.dart';
import 'estado_mapa.dart';

class ServicioBrouter {
  static const _canal = MethodChannel('offmaps/nativo');
  static const perfilDefecto = 'trekking';

  Future<bool> instalado() async =>
      await _canal.invokeMethod<bool>('brouterInstalado') ?? false;

  Future<bool> conectar() async =>
      await _canal.invokeMethod<bool>('conectarBrouter') ?? false;

  /// Calcula la ruta pasando por TODOS los puntos, en orden.
  /// Con 2 puntos: inicio → destino. Con 5: inicio → (via 3) → destino.
  Future<List<LatLong>> calcular(List<Punto> puntos,
      {String perfil = perfilDefecto}) async {
    if (puntos.length < 2) {
      throw Exception('Se necesitan al menos 2 puntos');
    }
    // BRouter espera: lon,lat|lon,lat|...  (¡longitud primero!)
    final lonlats = puntos
        .map((p) => '${p.lon.toStringAsFixed(6)},${p.lat.toStringAsFixed(6)}')
        .join('|');
    final gpx = await _canal.invokeMethod<String>(
        'calcularRuta', {'lonlats': lonlats, 'perfil': perfil});
    if (gpx == null) throw Exception('BRouter no devolvió resultado');
    final linea = parsearGpx(gpx);
    if (linea.isEmpty) {
      final vistazo = gpx.length > 150 ? gpx.substring(0, 150) : gpx;
      throw Exception('Ruta sin puntos (${gpx.length} caracteres). '
          'Respuesta inicial: $vistazo');
    }
    return linea;
  }

  List<LatLong> parsearGpx(String gpx) {
    final puntos = <LatLong>[];

    try {
      final doc = XmlDocument.parse(gpx);
      for (final n in doc.descendants.whereType<XmlElement>()) {
        if (n.name.local != 'trkpt') continue;
        final lat = double.tryParse(n.getAttribute('lat') ?? '');
        final lon = double.tryParse(n.getAttribute('lon') ?? '');
        if (lat != null && lon != null) puntos.add(LatLong(lat, lon));
      }
      if (puntos.isNotEmpty) return puntos;
    } catch (_) {
      // Fallback por regex, por si llega GPX mal formado.
    }

    final reLatLon = RegExp(r'<trkpt[^>]*lat="([\-0-9.]+)"[^>]*lon="([\-0-9.]+)"');
    for (final m in reLatLon.allMatches(gpx)) {
      final lat = double.tryParse(m.group(1)!);
      final lon = double.tryParse(m.group(2)!);
      if (lat != null && lon != null) puntos.add(LatLong(lat, lon));
    }

    if (puntos.isNotEmpty) return puntos;

    final reLonLat = RegExp(r'<trkpt[^>]*lon="([\-0-9.]+)"[^>]*lat="([\-0-9.]+)"');
    for (final m in reLonLat.allMatches(gpx)) {
      final lon = double.tryParse(m.group(1)!);
      final lat = double.tryParse(m.group(2)!);
      if (lat != null && lon != null) puntos.add(LatLong(lat, lon));
    }

    return puntos;
  }
}
