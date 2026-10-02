import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:geolocator/geolocator.dart';
import 'package:mapsforge_flutter/gesture.dart';
import 'package:mapsforge_flutter/mapsforge.dart';
import 'package:mapsforge_flutter/marker.dart';
import 'package:mapsforge_flutter/overlay.dart';
import 'package:mapsforge_flutter_core/model.dart';
import 'package:mapsforge_flutter_core/utils.dart';
import 'package:mapsforge_flutter_mapfile/mapfile.dart';
import 'package:mapsforge_flutter_renderer/cache.dart';
import 'package:mapsforge_flutter_renderer/offline_renderer.dart';
import 'package:mapsforge_flutter_rendertheme/rendertheme.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'estado_mapa.dart';
import 'servicio_brouter.dart';
import 'servicio_importacion.dart';
import 'servicio_tracks.dart';

const temaAsset = 'assets/render_theme/defaultrender.xml';
const latInicial = 4.6483;   // Bogotá; cámbiala si quieres otra posición inicial
const lonInicial = -74.0661;
const zoomInicial = 12;

enum ModoOrientacion { libre, norte, magnetico }

enum AjusteFitZoom { cercano, normal, amplio }

class PantallaMapa extends StatefulWidget {
  const PantallaMapa({super.key});
  @override
  State<PantallaMapa> createState() => _PantallaMapaState();
}

class _PantallaMapaState extends State<PantallaMapa> {
  static const _prefAjusteFitZoom = 'ajuste_fit_zoom';
  final estado = EstadoMapa();
  final brouter = ServicioBrouter();
  final importador = ServicioImportacion();
  final tracks = ServicioTracks();
  static const _canal = MethodChannel('offmaps/nativo');

  MapModel? _mapModel;
  Future<void>? _arranque;
  StreamSubscription? _subBrujula;
  StreamSubscription<Position>? _subTrack;
  StreamSubscription<Position>? _subPosicion;
  StreamSubscription<MapPosition>? _subZoomMapa;
  final List<TrackPunto> _puntosTrack = [];
  LatLong? _miPosicion;
  double? _miRumbo;
  int? _zoomVisual;
  ModoOrientacion _orientacion = ModoOrientacion.libre;
  AjusteFitZoom _ajusteFitZoom = AjusteFitZoom.normal;
  bool _importando = false;
  String? _aviso;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _arranque ??= _iniciar();
  }

  @override
  void dispose() {
    _subBrujula?.cancel();
    _subTrack?.cancel();
    _subPosicion?.cancel();
    _subZoomMapa?.cancel();
    _mapModel?.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------- arranque

  Future<void> _iniciar() async {
    try {
      await _iniciarInterno();
    } catch (e, st) {
      // Antes un error aquí quedaba silencioso y la app se quedaba en el spinner.
      debugPrint('OffMaps ERROR al iniciar: $e\n$st');
      if (mounted) {
        setState(() => _aviso = 'Error cargando el mapa:\n$e');
      }
    }
  }

  Future<void> _iniciarInterno() async {
    await _cargarAjusteFitZoom();
    _canal.setMethodCallHandler(_enLlamadaNativa);

    final permiso = await _canal.invokeMethod<bool>('permisoAlmacenamiento');
    debugPrint('OffMaps [1] permiso almacenamiento: $permiso');
    if (permiso != true) {
      setState(() => _aviso =
          'Concede "Todos los archivos" a OffMaps y vuelve a abrir la app.');
      return;
    }
    final mapas = (await _canal.invokeMethod<List<dynamic>>('listarMapas'))
            ?.cast<String>() ??
        const <String>[];
    debugPrint('OffMaps [2] mapas encontrados: $mapas');
    if (mapas.isEmpty) {
      setState(() => _aviso =
          'Copia un mapa .map (alternativaslibres) en la carpeta OffMaps del almacenamiento.');
      return;
    }
    final archivo = mapas.length == 1 ? mapas.first : await _elegir(mapas);
    if (archivo == null) return;
    if (!mounted) return;

    final f = File(archivo);
    debugPrint('OffMaps [3] archivo: $archivo existe=${await f.exists()} '
        'bytes=${await f.exists() ? await f.length() : 0}');

    // Diagnóstico de assets del tema: la declaración "assets/render_theme/"
    // del pubspec NO incluye subcarpetas (symbols, patterns...).
    final manifiesto = await AssetManifest.loadFromAssetBundle(rootBundle);
    final assetsTema = manifiesto
        .listAssets()
        .where((a) => a.startsWith('assets/render_theme/'))
        .toList();
    final carpetas = assetsTema
        .map((a) => a.split('/').sublist(0, a.split('/').length - 1).join('/'))
        .toSet();
    debugPrint('OffMaps [4] assets del tema: ${assetsTema.length} en $carpetas');
    if (!mounted) return;

    MapsforgeSettingsMgr()
        .setDeviceScaleFactor(View.of(context).devicePixelRatio);
    SymbolCacheMgr().addLoader(
      'jar:',
      ImageBundleLoader(
        bundle: rootBundle,
        pathPrefix: 'assets/render_theme/',
      ),
    );
    final datastore = await Mapfile.createFromFile(filename: archivo);
    debugPrint('OffMaps [5] datastore creado');
    final tema = await rootBundle.loadString(temaAsset);
    debugPrint('OffMaps [6] tema cargado: ${tema.length} caracteres');
    final rendertheme = RenderThemeBuilder.createFromString(tema);
    // Con Mapfile (no IsolateMapfile) habilitamos lectura/render en isolate
    // para mejorar rendimiento en zooms con mucha carga visual.
    final renderer = DatastoreRenderer(datastore, rendertheme, useIsolateReader: true);

    final modelo = MapModel(renderer: renderer, zoomlevelRange: const ZoomlevelRange(0, 21));
    final caja = await datastore.getBoundingBox();
    final centroLat = (caja.minLatitude + caja.maxLatitude) / 2;
    final centroLon = (caja.minLongitude + caja.maxLongitude) / 2;
    debugPrint('OffMaps [7] $archivo cubre lat ${caja.minLatitude}..${caja.maxLatitude}, '
        'lon ${caja.minLongitude}..${caja.maxLongitude}');
    modelo.setPosition(MapPosition(centroLat, centroLon, 11));
    _mapModel = modelo;
    _zoomVisual = modelo.lastPosition?.zoomlevel;

    await _subZoomMapa?.cancel();
    _subZoomMapa = modelo.positionStream.listen((p) {
      if (!mounted) return;
      if (_zoomVisual == p.zoomlevel) return;
      setState(() => _zoomVisual = p.zoomlevel);
    });

    // Pulsación prolongada = crear punto
    modelo.longTapStream.listen((ev) {
      if (ev != null) estado.agregarPunto(ev.latitude, ev.longitude);
    });

    // Coordenada recibida mientras la app no estaba lista
    final pendiente =
        await _canal.invokeMethod<Map<dynamic, dynamic>>('obtenerPendiente');
    if (pendiente != null) _recibirCoordenada(pendiente);

    debugPrint('OffMaps [8] modelo listo');
    unawaited(_iniciarIndicadorPosicion());
    setState(() {});
  }

  Future<void> _iniciarIndicadorPosicion() async {
    if (!mounted) return;
    final ok = await Geolocator.isLocationServiceEnabled();
    if (!ok) return;

    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
      return;
    }

    await _subPosicion?.cancel();
    _subPosicion = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 2,
      ),
    ).listen((p) {
      if (!mounted) return;
      final rumbo = p.heading;
      setState(() {
        _miPosicion = LatLong(p.latitude, p.longitude);
        if (rumbo.isFinite && rumbo >= 0) {
          _miRumbo = rumbo;
        }
      });
    });
  }

  Future<String?> _elegir(List<String> mapas) => showDialog<String>(
        context: context,
        builder: (c) => SimpleDialog(
          title: const Text('Elige el mapa base'),
          children: [
            for (final m in mapas)
              SimpleDialogOption(
                child: Text(m.split('/').last),
                onPressed: () => Navigator.pop(c, m),
              ),
          ],
        ),
      );

  Future<dynamic> _enLlamadaNativa(MethodCall call) async {
    if (call.method == 'coordenadaEntrante') {
      _recibirCoordenada(call.arguments as Map);
    }
    return null;
  }

  void _recibirCoordenada(Map datos) {
    final lat = (datos['lat'] as num?)?.toDouble();
    final lon = (datos['lon'] as num?)?.toDouble();
    if (lat == null || lon == null) return;
    estado.agregarPunto(lat, lon);
    _mapModel?.moveTo(lat, lon);
  }

  // ------------------------------------------------------------ acciones UI

  Future<void> _centrarGps() async {
    final pos = await _posicionActual();
    if (pos == null) return;
    setState(() {
      _miPosicion = LatLong(pos.latitude, pos.longitude);
      if (pos.heading.isFinite && pos.heading >= 0) {
        _miRumbo = pos.heading;
      }
    });
    _mapModel?.zoomToAround(pos.latitude, pos.longitude, 16);
  }

  Future<Position?> _posicionActual() async {
    final ok = await Geolocator.isLocationServiceEnabled();
    if (!ok) return null;
    LocationPermission perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      return null;
    }
    return Geolocator.getCurrentPosition();
  }

  Future<void> _agregarPuntoGps() async {
    final pos = await _posicionActual();
    if (pos == null) {
      _snack('No fue posible obtener la ubicación actual');
      return;
    }
    estado.agregarPunto(pos.latitude, pos.longitude);
    _mapModel?.moveTo(pos.latitude, pos.longitude);
  }

  Future<void> _trazarRuta() async {
    List<Punto> puntosRuta = List<Punto>.from(estado.puntos);
    if (puntosRuta.length < 2) {
      if (puntosRuta.length == 1) {
        final pos = await _posicionActual();
        if (pos == null) {
          _snack('Activa ubicación para trazar desde tu posición actual');
          return;
        }
        puntosRuta = [Punto(pos.latitude, pos.longitude, 'Mi ubicación'), ...puntosRuta];
      } else {
        _snack('Agrega al menos 2 puntos (o 1 punto + tu ubicación actual)');
        return;
      }
    }
    if (!await brouter.instalado() || !await brouter.conectar()) {
      _snack('Instala BRouter (btools.routingapp) con sus segmentos');
      return;
    }
    estado.setCalculando(true);
    try {
      final linea = await brouter.calcular(puntosRuta);
      estado.setTrazo(linea);
      _snack('Ruta lista: ${estado.kilometros.toStringAsFixed(1)} km');
    } catch (e) {
      _snack('Error: ${e.toString()}');
    } finally {
      estado.setCalculando(false);
    }
  }

  void _unToqueNorte() {
    _subBrujula?.cancel();
    _subBrujula = null;
    setState(() => _orientacion = ModoOrientacion.norte);
    _mapModel?.rotateTo(0);
  }

  void _dosToquesMagnetico() {
    setState(() => _orientacion = ModoOrientacion.magnetico);
    _subBrujula?.cancel();
    _subBrujula = FlutterCompass.events?.listen((e) {
      final rumbo = e.heading;
      if (rumbo != null) _mapModel?.rotateTo(-rumbo);
    });
  }

  void _compartir(Punto p) {
    final texto = '${p.lat.toStringAsFixed(6)}, ${p.lon.toStringAsFixed(6)}';
    showModalBottomSheet<void>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.share),
            title: const Text('Compartir coordenadas'),
            onTap: () async {
              await SharePlus.instance.share(ShareParams(text: texto));
              if (c.mounted) Navigator.pop(c);
            },
          ),
          ListTile(
            leading: const Icon(Icons.map),
            title: const Text('Abrir en Google Maps'),
            onTap: () async {
              final url = Uri.parse(
                  'https://www.google.com/maps/search/?api=1&query=${p.lat},${p.lon}');
              await launchUrl(url, mode: LaunchMode.externalApplication);
              if (c.mounted) Navigator.pop(c);
            },
          ),
        ]),
      ),
    );
  }

  Future<void> _compartirMiUbicacion() async {
    final pos = await _posicionActual();
    if (pos == null) {
      _snack('No fue posible obtener la ubicación actual');
      return;
    }
    final p = Punto(pos.latitude, pos.longitude, 'Mi ubicación');
    _compartir(p);
  }

  Future<void> _importarCapa() async {
    if (_importando) return;
    setState(() => _importando = true);
    try {
      final elegido = await _elegirArchivoDesdeOffMaps();
      if (elegido == null) return;

      final capa = await importador.cargarDesdeArchivo(elegido);
      if (capa.vacia) {
        _snack('Sin geometrías válidas en ${capa.nombre}');
        return;
      }
      estado.agregarCapaExterna(capa.nombre, capa.lineas, capa.poligonos);
      _snack('Importado ${capa.nombre}: ${capa.totalGeometrias} geometrías');
    } catch (e) {
      _snack('Error importando capa: $e');
    } finally {
      if (mounted) setState(() => _importando = false);
    }
  }

  Future<String?> _elegirArchivoDesdeOffMaps() async {
    final raiz = Directory(ServicioImportacion.carpetaOffMaps);
    if (!await raiz.exists()) {
      _snack('No existe carpeta /OffMaps');
      return null;
    }

    var actual = raiz.path;
    String? elegido;

    Future<List<FileSystemEntity>> cargar(String dir) async {
      final d = Directory(dir);
      final out = <FileSystemEntity>[];
      await for (final e in d.list(followLinks: false)) {
        if (e is Directory) {
          out.add(e);
        } else if (e is File && _esArchivoImportable(e.path)) {
          out.add(e);
        }
      }
      out.sort((a, b) {
        final ad = a is Directory;
        final bd = b is Directory;
        if (ad != bd) return ad ? -1 : 1;
        return a.path.toLowerCase().compareTo(b.path.toLowerCase());
      });
      return out;
    }

    var elementos = await cargar(actual);
    if (!mounted) return null;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (c) => StatefulBuilder(
        builder: (context, setModal) {
          Future<void> entrar(String ruta) async {
            final dir = Directory(ruta);
            if (!await dir.exists()) return;
            actual = dir.path;
            final nuevos = await cargar(actual);
            if (!context.mounted) return;
            setModal(() => elementos = nuevos);
          }

          final enRaiz = actual == raiz.path;
          final rel = actual.startsWith(raiz.path)
              ? actual.substring(raiz.path.length).replaceAll('\\', '/')
              : actual;
          final tituloRuta = rel.isEmpty ? '/OffMaps' : '/OffMaps$rel';

          return SafeArea(
            child: FractionallySizedBox(
              heightFactor: 0.75,
              child: Column(
                children: [
                  ListTile(
                    leading: IconButton(
                      icon: const Icon(Icons.arrow_upward),
                      onPressed: enRaiz
                          ? null
                          : () {
                              final padre = Directory(actual).parent.path;
                              if (!padre.startsWith(raiz.path)) return;
                              unawaited(entrar(padre));
                            },
                    ),
                    title: const Text('Importar archivo'),
                    subtitle: Text(tituloRuta),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: elementos.isEmpty
                        ? const Center(
                            child: Text('Sin archivos compatibles en esta carpeta'),
                          )
                        : ListView.builder(
                            itemCount: elementos.length,
                            itemBuilder: (context, i) {
                              final e = elementos[i];
                              final nombre = e.uri.pathSegments.last;
                              if (e is Directory) {
                                return ListTile(
                                  leading: const Icon(Icons.folder_outlined),
                                  title: Text(nombre),
                                  onTap: () => unawaited(entrar(e.path)),
                                );
                              }
                              return ListTile(
                                leading: const Icon(Icons.insert_drive_file_outlined),
                                title: Text(nombre),
                                onTap: () {
                                  elegido = e.path;
                                  Navigator.pop(context);
                                },
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );

    return elegido;
  }

  bool _esArchivoImportable(String ruta) {
    final n = ruta.toLowerCase();
    return n.endsWith('.gpx') || n.endsWith('.kml') || n.endsWith('.kmz');
  }

  void _abrirAccionesTrack() {
    showModalBottomSheet<void>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!estado.grabandoTrack)
              ListTile(
                leading: const Icon(Icons.fiber_manual_record, color: Colors.red),
                title: const Text('Iniciar grabación'),
                onTap: () async {
                  Navigator.pop(c);
                  await _iniciarGrabacionTrack();
                },
              ),
            if (estado.grabandoTrack && !estado.trackEnPausa)
              ListTile(
                leading: const Icon(Icons.pause_circle_outline),
                title: const Text('Pausar grabación'),
                onTap: () {
                  Navigator.pop(c);
                  _pausarTrack();
                },
              ),
            if (estado.grabandoTrack && estado.trackEnPausa)
              ListTile(
                leading: const Icon(Icons.play_circle_outline),
                title: const Text('Reanudar grabación'),
                onTap: () async {
                  Navigator.pop(c);
                  await _reanudarTrack();
                },
              ),
            if (estado.grabandoTrack)
              ListTile(
                leading: const Icon(Icons.stop_circle_outlined),
                title: const Text('Detener y guardar GPX'),
                onTap: () async {
                  Navigator.pop(c);
                  await _detenerYGuardarTrack();
                },
              ),
            if (!estado.grabandoTrack && estado.trackActual.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('Limpiar track actual'),
                onTap: () {
                  Navigator.pop(c);
                  _puntosTrack.clear();
                  estado.limpiarTrack();
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _iniciarGrabacionTrack() async {
    if (!await _asegurarPermisosTrack()) {
      return;
    }
    final pos = await _posicionActual();
    if (pos == null) {
      _snack('No fue posible iniciar la grabación (sin ubicación)');
      return;
    }

    await _subTrack?.cancel();
    _puntosTrack
      ..clear()
      ..add(TrackPunto(pos.latitude, pos.longitude, tiempo: pos.timestamp));
    estado.iniciarTrack();
    estado.agregarPuntoTrack(pos.latitude, pos.longitude);

    final settings = _settingsGrabacionTrack();
    _subTrack = Geolocator.getPositionStream(locationSettings: settings).listen(
      (p) {
        if (!estado.grabandoTrack || estado.trackEnPausa) return;
        if (p.accuracy > 120) return;

        final ultimo = _puntosTrack.isEmpty ? null : _puntosTrack.last;
        if (ultimo != null) {
          final d = haversineKm(ultimo.lat, ultimo.lon, p.latitude, p.longitude) * 1000;
          if (d < 1.5) return;
        }
        _puntosTrack.add(TrackPunto(p.latitude, p.longitude, tiempo: p.timestamp));
        estado.agregarPuntoTrack(p.latitude, p.longitude);
      },
      onError: (e) {
        _snack('Error de ubicación en grabación: $e');
      },
    );

    _snack('Grabación iniciada');
  }

  LocationSettings _settingsGrabacionTrack() {
    if (Platform.isAndroid) {
      return AndroidSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 1,
        intervalDuration: Duration(seconds: 2),
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'OffMaps grabando track',
          notificationText: 'Grabación activa en segundo plano',
          enableWakeLock: true,
          setOngoing: true,
        ),
      );
    }
    return const LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 5,
    );
  }

  void _pausarTrack() {
    if (!estado.grabandoTrack) return;
    estado.pausarTrack();
    _snack('Grabación en pausa');
  }

  Future<void> _reanudarTrack() async {
    if (!estado.grabandoTrack) return;
    final pos = await _posicionActual();
    estado.reanudarTrack();
    if (pos != null) {
      _puntosTrack.add(TrackPunto(pos.latitude, pos.longitude, tiempo: pos.timestamp));
      estado.agregarPuntoTrack(pos.latitude, pos.longitude);
    }
    _snack('Grabación reanudada');
  }

  Future<void> _detenerYGuardarTrack() async {
    if (!estado.grabandoTrack) return;
    await _subTrack?.cancel();
    _subTrack = null;
    estado.detenerTrack();

    final pos = await _posicionActual();
    if (pos != null) {
      final ultimo = _puntosTrack.isEmpty ? null : _puntosTrack.last;
      if (ultimo == null ||
          haversineKm(ultimo.lat, ultimo.lon, pos.latitude, pos.longitude) * 1000 >= 1) {
        _puntosTrack.add(TrackPunto(pos.latitude, pos.longitude, tiempo: pos.timestamp));
        estado.agregarPuntoTrack(pos.latitude, pos.longitude);
      }
    }

    if (_puntosTrack.length < 2) {
      _snack('Track muy corto, no se guardó (${_puntosTrack.length} punto)');
      return;
    }

    try {
      final ruta = await tracks.guardarTrackGpx(_puntosTrack);
      _snack('Track guardado: ${ruta.split('/').last}');
    } catch (e) {
      _snack('No se pudo guardar GPX: $e');
    }
  }

  Future<bool> _asegurarPermisosTrack() async {
    if (!Platform.isAndroid) return true;

    final notif = await _canal.invokeMethod<bool>('permisoNotificaciones') ?? false;
    final fondo = await _canal.invokeMethod<bool>('permisoUbicacionFondo') ?? false;

    if (!notif || !fondo) {
      _snack('Concede notificaciones y ubicación en segundo plano, luego reintenta');
      return false;
    }
    return true;
  }

  void _abrirCapasExternas() {
    showModalBottomSheet<void>(
      context: context,
      builder: (c) => SafeArea(
        child: ListenableBuilder(
          listenable: estado,
          builder: (context, _) {
            if (estado.capasExternas.isEmpty) {
              return const Padding(
                padding: EdgeInsets.all(24),
                child: Text('No hay capas importadas.'),
              );
            }
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(Icons.layers_clear_outlined),
                  title: const Text('Limpiar todas las capas'),
                  onTap: () {
                    estado.limpiarCapasExternas();
                    Navigator.pop(c);
                  },
                ),
                const Divider(height: 1),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: estado.capasExternas.length,
                    itemBuilder: (context, i) {
                      final capa = estado.capasExternas[i];
                      return ListTile(
                        leading: Icon(
                          capa.visible ? Icons.layers : Icons.layers_clear,
                        ),
                        title: Text(capa.nombre),
                        subtitle: Text('${capa.totalGeometrias} geometrías'),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: 'Zoom a capa',
                              icon: const Icon(Icons.center_focus_strong),
                              onPressed: () {
                                _zoomACapa(capa);
                                Navigator.pop(c);
                              },
                            ),
                            Switch(
                              value: capa.visible,
                              onChanged: (v) =>
                                  estado.alternarVisibilidadCapa(capa.id, v),
                            ),
                            IconButton(
                              tooltip: 'Eliminar capa',
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () => estado.eliminarCapa(capa.id),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  void _abrirAjustesFitZoom() {
    showModalBottomSheet<void>(
      context: context,
      builder: (c) => SafeArea(
        child: StatefulBuilder(
          builder: (context, setModal) {
            Widget opcion(AjusteFitZoom valor, String titulo, String subtitulo) {
              final activo = _ajusteFitZoom == valor;
              return ListTile(
                leading: Icon(activo ? Icons.radio_button_checked : Icons.radio_button_off),
                title: Text(titulo),
                subtitle: Text(subtitulo),
                onTap: () {
                  setState(() => _ajusteFitZoom = valor);
                  setModal(() {});
                  unawaited(_guardarAjusteFitZoom());
                },
              );
            }

            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const ListTile(
                  leading: Icon(Icons.tune),
                  title: Text('Ajuste de zoom al encuadrar'),
                ),
                opcion(AjusteFitZoom.cercano, 'Cercano', 'Zoom más alto al abrir capa/track'),
                opcion(AjusteFitZoom.normal, 'Normal', 'Balance recomendado'),
                opcion(AjusteFitZoom.amplio, 'Amplio', 'Muestra más contexto alrededor'),
                const SizedBox(height: 8),
              ],
            );
          },
        ),
      ),
    );
  }

  void _zoomACapa(CapaExterna capa) {
    final todos = <LatLong>[
      ...capa.lineas.expand((l) => l),
      ...capa.poligonos.expand((p) => p),
    ];
    _zoomABounds(todos);
  }

  void _zoomABounds(List<LatLong> puntos) {
    final modelo = _mapModel;
    if (modelo == null || puntos.isEmpty) return;

    var minLat = puntos.first.latitude;
    var maxLat = puntos.first.latitude;
    var minLon = puntos.first.longitude;
    var maxLon = puntos.first.longitude;
    for (final p in puntos.skip(1)) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLon) minLon = p.longitude;
      if (p.longitude > maxLon) maxLon = p.longitude;
    }

    final centroLat = (minLat + maxLat) / 2;
    final centroLon = (minLon + maxLon) / 2;

    final size = MediaQuery.sizeOf(context);
    final (factorW, factorH) = _factoresFitZoom();
    final usableW = math.max(80.0, size.width * factorW);
    final usableH = math.max(80.0, size.height * factorH);

    final minZoom = modelo.zoomlevelRange.zoomlevelMin;
    final maxZoom = modelo.zoomlevelRange.zoomlevelMax;
    var elegido = minZoom;

    for (var z = maxZoom; z >= minZoom; z--) {
      final x1 = _mercatorX(minLon, z);
      final x2 = _mercatorX(maxLon, z);
      final y1 = _mercatorY(maxLat, z);
      final y2 = _mercatorY(minLat, z);
      final dx = (x2 - x1).abs();
      final dy = (y2 - y1).abs();

      if (dx <= usableW && dy <= usableH) {
        elegido = z;
        break;
      }
    }

    modelo.setPosition(MapPosition(centroLat, centroLon, elegido));
  }

  (double, double) _factoresFitZoom() {
    switch (_ajusteFitZoom) {
      case AjusteFitZoom.cercano:
        return (0.90, 0.78);
      case AjusteFitZoom.normal:
        return (0.80, 0.65);
      case AjusteFitZoom.amplio:
        return (0.68, 0.52);
    }
  }

  Future<void> _cargarAjusteFitZoom() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final guardado = prefs.getString(_prefAjusteFitZoom);
      _ajusteFitZoom = AjusteFitZoom.values.firstWhere(
        (v) => v.name == guardado,
        orElse: () => AjusteFitZoom.normal,
      );
    } catch (_) {
      _ajusteFitZoom = AjusteFitZoom.normal;
    }
  }

  Future<void> _guardarAjusteFitZoom() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefAjusteFitZoom, _ajusteFitZoom.name);
    } catch (_) {
      // Ignorar fallo de persistencia para no bloquear UI.
    }
  }

  double _mercatorX(double lon, int zoom) {
    final world = 256.0 * math.pow(2.0, zoom).toDouble();
    return (lon + 180.0) / 360.0 * world;
  }

  double _mercatorY(double lat, int zoom) {
    final world = 256.0 * math.pow(2.0, zoom).toDouble();
    final clampedLat = lat.clamp(-85.05112878, 85.05112878);
    final rad = clampedLat * math.pi / 180.0;
    final y = (1 - (math.log(math.tan(rad) + (1 / math.cos(rad))) / math.pi)) / 2;
    return y * world;
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ------------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final modelo = _mapModel;
    final zoomActual = _zoomVisual ?? modelo?.lastPosition?.zoomlevel ?? zoomInicial;
    return Scaffold(
      body: _aviso != null
          ? _pantallaAviso()
          : modelo == null
              ? const Center(child: CircularProgressIndicator())
              : ListenableBuilder(
                  listenable: estado,
                  builder: (context, _) => Stack(
                    children: [
                      // gestos: un toque, doble toque, pulsación larga, mover, zoom, rotar
                      GenericGestureDetector(mapModel: modelo),
                      ...modelo.renderers
                          .map((r) => TileView(mapModel: modelo, renderer: r)),
                      if (zoomActual >= 15)
                        ...modelo.labelRenderers
                            .map((r) => LabelView(mapModel: modelo, renderer: r)),
                      MarkerDatastoreOverlay(
                        mapModel: modelo,
                        datastore: _construirMarcadores(),
                        zoomlevelRange: ZoomlevelRange.standard(),
                      ),
                      if (zoomActual >= 13) DistanceOverlay(mapModel: modelo),
                      _badgeTrack(),
                      _panelInferior(),
                      _botonesLaterales(modelo),
                    ],
                  ),
                ),
    );
  }

  Widget _pantallaAviso() => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.map_outlined, size: 64),
              const SizedBox(height: 16),
              Text(_aviso!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => setState(() {
                  _aviso = null;
                  _arranque = _iniciar();
                }),
                child: const Text('Reintentar'),
              ),
            ],
          ),
        ),
      );

  MarkerDatastore _construirMarcadores() {
    final ds = DefaultMarkerDatastore();
    final zoom = _zoomVisual ?? _mapModel?.lastPosition?.zoomlevel ?? zoomInicial;

    if (_miPosicion != null) {
      final p = _miPosicion!;
      ds.addMarker(CircleMarker(
        latLong: p,
        radius: _radioPunto(zoom, base: 2.2, maximo: 4.2),
        fillColor: 0xFF1E88E5,
        strokeColor: 0xFFFFFFFF,
        strokeWidth: 1.2,
      ));

      final rumbo = _miRumbo;
      if (rumbo != null) {
        ds.addMarker(IconMarker(
          latLong: p,
          iconData: Icons.navigation_rounded,
          rotation: rumbo,
          size: _tamIconoRumbo(zoom),
          bitmapColor: 0xFF0D47A1,
        ));
      }
    }

    for (final linea in estado.lineasExternasVisibles) {
      if (linea.length < 2) continue;
      ds.addMarker(PolylineMarker(
        path: List<LatLong>.from(linea),
        strokeWidth: 4,
        strokeColor: 0xFF1565C0,
      ));
    }

    for (final poligono in estado.poligonosExternosVisibles) {
      if (poligono.length < 4) continue;
      ds.addMarker(AreaMarker(
        path: List<LatLong>.from(poligono),
        strokeWidth: 3,
        strokeColor: 0xFF8E24AA,
        fillColor: 0x338E24AA,
      ));
    }

    for (var i = 0; i < estado.puntos.length; i++) {
      final p = estado.puntos[i];
      final esInicio = i == 0;
      final esFin = i == estado.puntos.length - 1 && estado.puntos.length > 1;
      ds.addMarker(CircleMarker(
        latLong: LatLong(p.lat, p.lon),
        radius: _radioPunto(
          zoom,
          base: esInicio || esFin ? 1.8 : 1.6,
          maximo: esInicio || esFin ? 3.2 : 2.8,
        ),
        fillColor: esInicio
            ? 0xCC0B7A3E
            : (esFin ? 0xCCB00020 : 0xCC1565C0),
        strokeColor: 0xFFFFFFFF,
        strokeWidth: 1,
      ));
    }
    if (estado.trazo.length > 1) {
      ds.addMarker(PolylineMarker(
        path: List<LatLong>.from(estado.trazo),
        strokeWidth: 6,
        strokeColor: 0xFF0B7A3E,
      ));
    }
    if (estado.trackActual.length > 1) {
      ds.addMarker(PolylineMarker(
        path: List<LatLong>.from(estado.trackActual),
        strokeWidth: 5,
        strokeColor: estado.trackEnPausa ? 0xFFFFA000 : 0xFFD32F2F,
      ));
    }
    return ds;
  }

  double _radioPunto(int zoom, {required double base, required double maximo}) {
    final t = ((15 - zoom) / 8).clamp(0.0, 1.0);
    return base + (maximo - base) * t;
  }

  double _tamIconoRumbo(int zoom) {
    if (zoom >= 19) return 10;
    if (zoom >= 17) return 12;
    if (zoom >= 15) return 14;
    if (zoom >= 13) return 16;
    return 18;
  }

  Widget _botonesLaterales(MapModel modelo) => Positioned(
        right: 12,
        bottom: 120,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // GPS: un toque centra
            _BotonIcono(
              icono: Icons.my_location,
              onTap: _centrarGps,
            ),
            const SizedBox(height: 12),
            _BotonIcono(
              icono: estado.grabandoTrack
                  ? (estado.trackEnPausa ? Icons.pause_circle : Icons.fiber_manual_record)
                  : Icons.trip_origin,
              color: estado.grabandoTrack
                  ? (estado.trackEnPausa ? Colors.amber : Colors.red)
                  : null,
              onTap: _abrirAccionesTrack,
            ),
            const SizedBox(height: 12),
            _BotonIcono(
              icono: _importando ? Icons.hourglass_top : Icons.file_open_outlined,
              onTap: _importando ? null : _importarCapa,
            ),
            const SizedBox(height: 12),
            _BotonIcono(
              icono: Icons.add_location_alt_outlined,
              onTap: _agregarPuntoGps,
            ),
            const SizedBox(height: 12),
            _BotonIcono(
              icono: Icons.tune,
              onTap: _abrirAjustesFitZoom,
            ),
            const SizedBox(height: 12),
            // Norte: 1 toque = norte arriba · 2 toques = norte magnético
            _BotonIcono(
              icono: _orientacion == ModoOrientacion.magnetico
                  ? Icons.explore
                  : Icons.navigation_outlined,
              color: _orientacion == ModoOrientacion.libre ? null : Colors.green,
              onTap: _unToqueNorte,
              onDoubleTap: _dosToquesMagnetico,
            ),
            const SizedBox(height: 12),
            // Compartir último punto
            if (estado.puntos.isNotEmpty)
              _BotonIcono(
                icono: Icons.share,
                onTap: () => _compartir(estado.puntos.last),
              ),
            const SizedBox(height: 12),
            _BotonIcono(
              icono: Icons.near_me_outlined,
              onTap: _compartirMiUbicacion,
            ),
            const SizedBox(height: 12),
            if (estado.capasExternas.isNotEmpty)
              _BotonIcono(
                icono: Icons.layers_outlined,
                onTap: _abrirCapasExternas,
              ),
            if (estado.capasExternas.isNotEmpty)
              const SizedBox(height: 12),
            _BotonIcono(
              icono: Icons.delete_outline,
              onTap: estado.puntos.isEmpty ? null : estado.limpiar,
            ),
          ],
        ),
      );

  Widget _badgeTrack() {
    if (estado.trackActual.isEmpty) return const SizedBox.shrink();
    final texto = estado.grabandoTrack
        ? (estado.trackEnPausa ? 'Track en pausa' : 'Grabando track')
        : 'Track listo';
    final color = estado.grabandoTrack
        ? (estado.trackEnPausa ? Colors.amber.shade800 : Colors.red.shade700)
        : Colors.blueGrey;

    return Positioned(
      left: 12,
      top: 24,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          '$texto · ${estado.kilometrosTrack.toStringAsFixed(2)} km',
          style: const TextStyle(color: Colors.white, fontSize: 12),
        ),
      ),
    );
  }

  Widget _panelInferior() => Positioned(
        left: 0,
        right: 0,
        bottom: 24,
        child: Center(
          child: FilledButton.tonalIcon(
            onPressed: estado.calculando ? null : _trazarRuta,
            icon: estado.calculando
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.route),
            label: Text(estado.puntos.length < 2
                ? (estado.puntos.length == 1
                    ? 'Trazar desde mi ubicación'
                    : 'Toca prolongado para agregar puntos')
                : estado.trazo.isEmpty
                    ? 'Trazar ruta (${estado.puntos.length} puntos)'
                    : '${estado.kilometros.toStringAsFixed(1)} km · re-trazar'),
          ),
        ),
      );
}

class _BotonIcono extends StatelessWidget {
  final IconData icono;
  final VoidCallback? onTap;
  final VoidCallback? onDoubleTap;
  final Color? color;

  const _BotonIcono({required this.icono, this.onTap, this.onDoubleTap, this.color});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onDoubleTap: onDoubleTap,
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          shape: BoxShape.circle,
          boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)],
        ),
        child: CircleAvatar(
          radius: 22,
          backgroundColor: Colors.transparent,
          child: Icon(icono, color: color),
        ),
      ),
    );
  }
}
