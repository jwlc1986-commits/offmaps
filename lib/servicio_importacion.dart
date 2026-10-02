import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:mapsforge_flutter_core/model.dart';
import 'package:xml/xml.dart';

class CapaImportada {
  final String nombre;
  final List<List<LatLong>> lineas;
  final List<List<LatLong>> poligonos;

  const CapaImportada({
    required this.nombre,
    required this.lineas,
    required this.poligonos,
  });

  bool get vacia => lineas.isEmpty && poligonos.isEmpty;
  int get totalGeometrias => lineas.length + poligonos.length;
}

class ServicioImportacion {
  static const carpetaOffMaps = '/storage/emulated/0/OffMaps';

  Future<List<String>> listarArchivos() async {
    final dir = Directory(carpetaOffMaps);
    if (!await dir.exists()) return const [];

    final resultados = <String>[];
    await for (final e in dir.list(followLinks: false)) {
      if (e is! File) continue;
      final n = e.path.toLowerCase();
      if (n.endsWith('.gpx') || n.endsWith('.kml') || n.endsWith('.kmz')) {
        resultados.add(e.path);
      }
    }
    resultados.sort();
    return resultados;
  }

  Future<CapaImportada> cargarDesdeArchivo(String ruta) async {
    final archivo = File(ruta);
    if (!await archivo.exists()) {
      throw Exception('No existe el archivo: $ruta');
    }

    final nombre = ruta.split('/').last;
    final lower = ruta.toLowerCase();
    if (lower.endsWith('.gpx')) {
      final texto = await archivo.readAsString();
      return parsearGpxTexto(nombre: nombre, texto: texto);
    }
    if (lower.endsWith('.kml')) {
      final texto = await archivo.readAsString();
      return parsearKmlTexto(nombre: nombre, texto: texto);
    }
    if (lower.endsWith('.kmz')) {
      final bytes = await archivo.readAsBytes();
      return parsearKmzBytes(nombre: nombre, bytes: bytes);
    }

    throw Exception('Formato no soportado: $ruta');
  }

  CapaImportada parsearGpxTexto({required String nombre, required String texto}) {
    final doc = XmlDocument.parse(texto);
    final lineas = <List<LatLong>>[];

    final elementos = doc.descendants.whereType<XmlElement>();

    for (final seg in elementos.where((e) => e.name.local == 'trkseg')) {
      final pts = <LatLong>[];
      for (final trkpt in seg.children.whereType<XmlElement>().where((e) => e.name.local == 'trkpt')) {
        final lat = double.tryParse(trkpt.getAttribute('lat') ?? '');
        final lon = double.tryParse(trkpt.getAttribute('lon') ?? '');
        if (lat != null && lon != null) pts.add(LatLong(lat, lon));
      }
      if (pts.length > 1) lineas.add(pts);
    }

    for (final rte in elementos.where((e) => e.name.local == 'rte')) {
      final pts = <LatLong>[];
      for (final rtept in rte.children.whereType<XmlElement>().where((e) => e.name.local == 'rtept')) {
        final lat = double.tryParse(rtept.getAttribute('lat') ?? '');
        final lon = double.tryParse(rtept.getAttribute('lon') ?? '');
        if (lat != null && lon != null) pts.add(LatLong(lat, lon));
      }
      if (pts.length > 1) lineas.add(pts);
    }

    return CapaImportada(nombre: nombre, lineas: lineas, poligonos: const []);
  }

  CapaImportada parsearKmlTexto({required String nombre, required String texto}) {
    final doc = XmlDocument.parse(texto);
    final elementos = doc.descendants.whereType<XmlElement>();
    final lineas = <List<LatLong>>[];
    final poligonos = <List<LatLong>>[];

    for (final lineString in elementos.where((e) => e.name.local == 'LineString')) {
      final coords = _textoCoordenadas(lineString);
      final pts = _parsearCoordenadasKml(coords);
      if (pts.length > 1) lineas.add(pts);
    }

    for (final polygon in elementos.where((e) => e.name.local == 'Polygon')) {
      final outer = polygon
          .descendants
          .whereType<XmlElement>()
          .where((e) => e.name.local == 'outerBoundaryIs')
          .toList();

      if (outer.isNotEmpty) {
        for (final o in outer) {
          final coords = _textoCoordenadas(o);
          final pts = _cerrarPoligono(_parsearCoordenadasKml(coords));
          if (pts.length > 3) poligonos.add(pts);
        }
      } else {
        final coords = _textoCoordenadas(polygon);
        final pts = _cerrarPoligono(_parsearCoordenadasKml(coords));
        if (pts.length > 3) poligonos.add(pts);
      }
    }

    return CapaImportada(nombre: nombre, lineas: lineas, poligonos: poligonos);
  }

  CapaImportada parsearKmzBytes({required String nombre, required List<int> bytes}) {
    final zip = ZipDecoder().decodeBytes(bytes);
    ArchiveFile? kml;

    for (final f in zip.files.where((f) => f.isFile)) {
      final n = f.name.toLowerCase();
      if (n.endsWith('doc.kml')) {
        kml = f;
        break;
      }
      if (n.endsWith('.kml')) {
        kml ??= f;
      }
    }

    if (kml == null) throw Exception('El KMZ no contiene KML');
    final texto = _decodeTexto(kml.readBytes());
    return parsearKmlTexto(nombre: nombre, texto: texto);
  }

  String _decodeTexto(List<int>? bytes) {
    if (bytes == null) return '';
    try {
      return utf8.decode(bytes);
    } catch (_) {
      return latin1.decode(bytes);
    }
  }

  List<LatLong> _parsearCoordenadasKml(String coords) {
    final limpio = coords.replaceAll('\n', ' ').replaceAll('\t', ' ').trim();
    if (limpio.isEmpty) return const [];

    final puntos = <LatLong>[];
    for (final par in limpio.split(RegExp(r'\s+'))) {
      final partes = par.split(',');
      if (partes.length < 2) continue;
      final lon = double.tryParse(partes[0]);
      final lat = double.tryParse(partes[1]);
      if (lat != null && lon != null) puntos.add(LatLong(lat, lon));
    }
    return puntos;
  }

  String _textoCoordenadas(XmlElement e) {
    for (final n in e.descendants.whereType<XmlElement>()) {
      if (n.name.local == 'coordinates') return n.innerText;
    }
    return '';
  }

  List<LatLong> _cerrarPoligono(List<LatLong> puntos) {
    if (puntos.length < 3) return const [];
    final primero = puntos.first;
    final ultimo = puntos.last;
    if (primero.latitude == ultimo.latitude &&
        primero.longitude == ultimo.longitude) {
      return puntos;
    }
    return [...puntos, primero];
  }
}
