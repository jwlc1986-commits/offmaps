import 'dart:io';

import 'package:mapsforge_flutter_core/model.dart';
import 'package:xml/xml.dart';

class TrackPunto {
  final double lat;
  final double lon;
  final DateTime? tiempo;

  const TrackPunto(this.lat, this.lon, {this.tiempo});
}

class TrackArchivo {
  final String ruta;
  final String nombre;
  final int bytes;
  final DateTime modificado;

  const TrackArchivo({
    required this.ruta,
    required this.nombre,
    required this.bytes,
    required this.modificado,
  });
}

class ServicioTracks {
  static const carpetaTracks = '/storage/emulated/0/OffMaps/tracks';

  Future<String> guardarTrackGpx(List<TrackPunto> puntos, {String? nombreBase}) async {
    if (puntos.length < 2) {
      throw Exception('Se requieren al menos 2 puntos para guardar track');
    }

    final dir = Directory(carpetaTracks);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    final ahora = DateTime.now();
    final nombre = (nombreBase == null || nombreBase.trim().isEmpty)
        ? _nombrePorFecha(ahora)
        : nombreBase.trim();
    final archivo = File('${dir.path}/$nombre.gpx');
    final gpx = construirGpx(nombre: nombre, puntos: puntos);
    await archivo.writeAsString(gpx, flush: true);
    return archivo.path;
  }

  Future<List<TrackArchivo>> listarTracks() async {
    final dir = Directory(carpetaTracks);
    if (!await dir.exists()) return const [];

    final tracks = <TrackArchivo>[];
    await for (final e in dir.list(followLinks: false)) {
      if (e is! File) continue;
      if (!e.path.toLowerCase().endsWith('.gpx')) continue;
      final stat = await e.stat();
      tracks.add(TrackArchivo(
        ruta: e.path,
        nombre: e.uri.pathSegments.last,
        bytes: stat.size,
        modificado: stat.modified,
      ));
    }

    tracks.sort((a, b) => b.modificado.compareTo(a.modificado));
    return tracks;
  }

  Future<void> eliminarTrack(String ruta) async {
    final f = File(ruta);
    if (await f.exists()) {
      await f.delete();
    }
  }

  Future<String> renombrarTrack(String ruta, String nuevoNombreBase) async {
    var limpio = nuevoNombreBase.trim();
    if (limpio.isEmpty) throw Exception('Nombre inválido');
    limpio = limpio.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    if (!limpio.toLowerCase().endsWith('.gpx')) {
      limpio = '$limpio.gpx';
    }

    final original = File(ruta);
    if (!await original.exists()) throw Exception('El archivo no existe');

    final destino = File('${original.parent.path}/$limpio');
    if (await destino.exists()) {
      throw Exception('Ya existe un track con ese nombre');
    }

    final renombrado = await original.rename(destino.path);
    return renombrado.path;
  }

  Future<List<LatLong>> cargarTrackComoLinea(String ruta) async {
    final archivo = File(ruta);
    if (!await archivo.exists()) throw Exception('No existe el track');
    final gpx = await archivo.readAsString();
    return parsearGpxLinea(gpx);
  }

  List<LatLong> parsearGpxLinea(String gpx) {
    final puntos = <LatLong>[];
    final doc = XmlDocument.parse(gpx);
    for (final n in doc.descendants.whereType<XmlElement>()) {
      if (n.name.local != 'trkpt') continue;
      final lat = double.tryParse(n.getAttribute('lat') ?? '');
      final lon = double.tryParse(n.getAttribute('lon') ?? '');
      if (lat != null && lon != null) puntos.add(LatLong(lat, lon));
    }
    return puntos;
  }

  String construirGpx({required String nombre, required List<TrackPunto> puntos}) {
    final sb = StringBuffer();
    sb.writeln('<?xml version="1.0" encoding="UTF-8"?>');
    sb.writeln('<gpx version="1.1" creator="OffMaps" xmlns="http://www.topografix.com/GPX/1/1">');
    sb.writeln('  <metadata>');
    sb.writeln('    <name>${_escape(nombre)}</name>');
    sb.writeln('    <time>${DateTime.now().toUtc().toIso8601String()}</time>');
    sb.writeln('  </metadata>');
    sb.writeln('  <trk>');
    sb.writeln('    <name>${_escape(nombre)}</name>');
    sb.writeln('    <trkseg>');
    for (final p in puntos) {
      sb.write('      <trkpt lat="${p.lat.toStringAsFixed(7)}" lon="${p.lon.toStringAsFixed(7)}">');
      if (p.tiempo != null) {
        sb.write('<time>${p.tiempo!.toUtc().toIso8601String()}</time>');
      }
      sb.writeln('</trkpt>');
    }
    sb.writeln('    </trkseg>');
    sb.writeln('  </trk>');
    sb.writeln('</gpx>');
    return sb.toString();
  }

  String _nombrePorFecha(DateTime d) {
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    final h = d.hour.toString().padLeft(2, '0');
    final min = d.minute.toString().padLeft(2, '0');
    final s = d.second.toString().padLeft(2, '0');
    return 'track_$y-$m-$day' '_$h-$min-$s';
  }

  String _escape(String text) {
    return text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }
}
