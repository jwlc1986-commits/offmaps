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

import 'estado_mapa.dart';
import 'renderer_medido.dart';
import 'servicio_brouter.dart';
import 'servicio_importacion.dart';
import 'servicio_tracks.dart';

const temaAsset = 'assets/render_theme/defaultrender.xml';
const latInicial = 4.6483;   // Bogotá; cámbiala si quieres otra posición inicial
const lonInicial = -74.0661;
const zoomInicial = 12;

/// Zoom mínimo permitido (0 = sin límite). Hipótesis: en zooms bajos cada tile abarca una
/// zona enorme del mapa de toda Colombia y es lo más lento de dibujar. Compruébalo con los
/// logs "OffMaps TILES z=..." y ajusta este valor.
const zoomMinimo = 8;

/// Diagnóstico (logs "OffMaps ..." y medición de tiles).
/// Para priorizar rendimiento, queda apagado por defecto también en debug.
/// Si quieres activarlo temporalmente: --dart-define=DIAGNOSTICO=true
const diagnostico = bool.fromEnvironment('DIAGNOSTICO', defaultValue: false);

void _diag(String mensaje) {
  if (diagnostico) debugPrint(mensaje);
}

/// Factor de escala máximo que se le da a mapsforge (0 = usar la densidad real de la pantalla).
/// mapsforge pide una cantidad de tiles que crece con el CUADRADO de este factor: con el
/// Motorola (2.81) pide 324 tiles por pantalla; con 1.5 serían unos 110; con 1.0, unos 45.
/// A cambio, el mapa se ve menos nítido y los elementos (texto, marcadores) más grandes.
/// Valor de prueba para priorizar fluidez.
/// 1.0 = más rápido (menos nitidez). 1.5/2.0 = más nítido (más lento).
const escalaMapaMaxima = 1.0;

/// true  = el punto de pulsación larga se calcula con la posición del mapa en el instante
///         en que pones el dedo (así lo hace la librería).
/// false = con la posición del mapa cuando se cumple la pulsación (350 ms después).
const puntoConPosicionAlTocar = true;

enum ModoOrientacion { libre, norte, magnetico }

enum AjusteFitZoom { cercano, normal, amplio }

class _PerfilRuta {
  final String id;
  final String nombre;
  const _PerfilRuta(this.id, this.nombre);
}

class PantallaMapa extends StatefulWidget {
  const PantallaMapa({super.key});
  @override
  State<PantallaMapa> createState() => _PantallaMapaState();
}

class _PantallaMapaState extends State<PantallaMapa> {
  static const _prefAjusteFitZoom = 'ajuste_fit_zoom';
  static const _prefEscalaPuntos = 'ui_escala_puntos';
  static const _prefEscalaPosicion = 'ui_escala_posicion';
  static const _prefGrosorRuta = 'ui_grosor_ruta';
  static const _prefGrosorTrack = 'ui_grosor_track';
  static const _prefMostrarEtiquetas = 'ui_mostrar_etiquetas';
  static const _prefPerfilRuta = 'ui_perfil_ruta';
  static const _perfilesRuta = <_PerfilRuta>[
    _PerfilRuta('car-fast', 'Vehículo'),
    _PerfilRuta('fastbike', 'Bicicleta'),
    _PerfilRuta('trekking', 'Peatonal'),
  ];
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
  StreamSubscription<TapEvent?>? _subTapMapa;
  final List<TrackPunto> _puntosTrack = [];
  LatLong? _miPosicion;
  double? _miRumbo;
  int? _zoomVisual;
  ModoOrientacion _orientacion = ModoOrientacion.libre;
  AjusteFitZoom _ajusteFitZoom = AjusteFitZoom.normal;
  double _escalaPuntos = 1.0;
  double _escalaPosicion = 6.0;
  double _grosorRuta = 2.2;
  double _grosorTrack = 2.4;
  bool _mostrarEtiquetas = true;
  String _perfilRuta = 'trekking';
  bool _panelRutaAbierto = false;
  int _punterosActivos = 0;
  MapPosition? _posAlTocar;
  Offset? _offsetAlTocar;
  Timer? _temporizadorLongPress;
  int? _punteroLongPress;
  Offset? _inicioLongPress;
  bool _multitouchEnCurso = false;
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
    _subTapMapa?.cancel();
    _temporizadorLongPress?.cancel();
    _mapModel?.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------- arranque

  Future<void> _iniciar() async {
    try {
      await _iniciarInterno();
    } catch (e, st) {
      // Antes un error aquí quedaba silencioso y la app se quedaba en el spinner.
      debugPrint('OffMaps ERROR al iniciar: $e\n$st'); // los errores se muestran siempre
      if (mounted) {
        setState(() => _aviso = 'Error cargando el mapa:\n$e');
      }
    }
  }

  Future<void> _iniciarInterno() async {
    await _cargarAjustesUI();
    _canal.setMethodCallHandler(_enLlamadaNativa);

    final permiso = await _canal.invokeMethod<bool>('permisoAlmacenamiento');
    _diag('OffMaps [1] permiso almacenamiento: $permiso');
    if (permiso != true) {
      setState(() => _aviso =
          'Concede "Todos los archivos" a OffMaps y vuelve a abrir la app.');
      return;
    }
    final mapas = (await _canal.invokeMethod<List<dynamic>>('listarMapas'))
            ?.cast<String>() ??
        const <String>[];
    _diag('OffMaps [2] mapas encontrados: $mapas');
    if (mapas.isEmpty) {
      setState(() => _aviso =
          'Copia un mapa .map (alternativaslibres) en la carpeta OffMaps del almacenamiento.');
      return;
    }
    final archivo = mapas.length == 1 ? mapas.first : await _elegir(mapas);
    if (archivo == null) return;
    if (!mounted) return;

    if (diagnostico) {
      final f = File(archivo);
      final existe = await f.exists();
      _diag('OffMaps [3] archivo: $archivo existe=$existe '
          'bytes=${existe ? await f.length() : 0}');

      // La declaración "assets/render_theme/" del pubspec NO incluye subcarpetas;
      // se listan las carpetas que sí quedaron empaquetadas.
      final manifiesto = await AssetManifest.loadFromAssetBundle(rootBundle);
      final assetsTema = manifiesto
          .listAssets()
          .where((a) => a.startsWith('assets/render_theme/'))
          .toList();
      final carpetas = assetsTema
          .map((a) => a.split('/').sublist(0, a.split('/').length - 1).join('/'))
          .toSet();
      _diag('OffMaps [4] assets del tema: ${assetsTema.length} en $carpetas');
    }
    if (!mounted) return;

    // Todo lo que necesita BuildContext se lee aquí, justo después de comprobar mounted
    // y antes de los siguientes await (así no se usa el context tras una espera).
    final dprReal = View.of(context).devicePixelRatio;
    final tamPantalla = MediaQuery.sizeOf(context);
    final dprMapa =
        (escalaMapaMaxima > 0 && dprReal > escalaMapaMaxima) ? escalaMapaMaxima : dprReal;
    MapsforgeSettingsMgr().setDeviceScaleFactor(dprMapa);
    SymbolCacheMgr().addLoader(
      'jar:',
      ImageBundleLoader(
        bundle: rootBundle,
        pathPrefix: 'assets/render_theme/',
      ),
    );
    final datastore = await IsolateMapfile.createFromFile(filename: archivo);
    _diag('OffMaps [5] datastore creado');
    final tema = await rootBundle.loadString(temaAsset);
    _diag('OffMaps [6] tema cargado: ${tema.length} caracteres');
    final rendertheme = RenderThemeBuilder.createFromString(tema);
    // IsolateMapfile ya corre lectura en su propio isolate; mantener
    // useIsolateReader=false evita el problema de objetos no enviables.
    final rendererBase = DatastoreRenderer(datastore, rendertheme, useIsolateReader: false);
    // Con diagnóstico se mide cuánto tarda cada tile (líneas "OffMaps TILES").
    final Renderer renderer = diagnostico ? RendererMedido(rendererBase) : rendererBase;

    final modelo = MapModel(renderer: renderer, zoomlevelRange: const ZoomlevelRange(zoomMinimo, 21));
    final caja = await datastore.getBoundingBox();
    _diag('OffMaps [7] $archivo cubre lat ${caja.minLatitude}..${caja.maxLatitude}, '
        'lon ${caja.minLongitude}..${caja.maxLongitude}');
    modelo.setPosition(MapPosition(latInicial, lonInicial, zoomInicial));
    _mapModel = modelo;
    _zoomVisual = modelo.lastPosition?.zoomlevel;

    await _subZoomMapa?.cancel();
    _subZoomMapa = modelo.positionStream.listen((p) {
      if (!mounted) return;
      if (_zoomVisual == p.zoomlevel) return;
      _diag('OffMaps ZOOM $_zoomVisual -> ${p.zoomlevel}');
      setState(() => _zoomVisual = p.zoomlevel);
    });

    await _subTapMapa?.cancel();
    _subTapMapa = modelo.tapStream.listen((ev) {
      if (ev == null) return;
      final indice = _indicePuntoCercanoTap(ev);
      if (indice != null) {
        estado.quitarPunto(indice);
        _snack('Punto eliminado');
        return;
      }
      if (_tapSobreRuta(ev)) {
        _abrirTarjetaRuta();
      }
    });

    // Solo diagnóstico: coordenada que calcula la librería para la pulsación larga.
    if (diagnostico) {
      modelo.longTapStream.listen((ev) {
        if (ev == null) return;
        _diag('OffMaps PUNTO(librería) lat=${ev.latitude.toStringAsFixed(6)} '
            'lon=${ev.longitude.toStringAsFixed(6)} zoom=${modelo.lastPosition?.zoomlevel}');
      });
    }

    // Si el usuario manipula el mapa, volver a modo libre para permitir
    // giros/manual sin que el modo magnético lo fuerce de nuevo.
    modelo.manualMoveStream.listen((_) {
      if (!mounted) return;
      if (_orientacion == ModoOrientacion.libre) return;
      _subBrujula?.cancel();
      _subBrujula = null;
      setState(() => _orientacion = ModoOrientacion.libre);
    });

    // Coordenada recibida mientras la app no estaba lista
    final pendiente =
        await _canal.invokeMethod<Map<dynamic, dynamic>>('obtenerPendiente');
    if (pendiente != null) _recibirCoordenada(pendiente);

    _diag('OffMaps [8] modelo listo');
    _diag('OffMaps [config] dprReal=${dprReal.toStringAsFixed(2)} '
        'dprMapa=${MapsforgeSettingsMgr().getDeviceScaleFactor().toStringAsFixed(2)} '
        'pantalla=${tamPantalla.width.toStringAsFixed(0)}x${tamPantalla.height.toStringAsFixed(0)} dp '
        '(${(tamPantalla.width * dprReal).round()}x${(tamPantalla.height * dprReal).round()} px) '
        'tileSize=${MapsforgeSettingsMgr().tileSize} zoomMinimo=$zoomMinimo');
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
        accuracy: LocationAccuracy.medium,
        distanceFilter: 8,
      ),
    ).listen((p) {
      if (!mounted) return;
      final rumbo = p.heading;
      final nuevaPos = LatLong(p.latitude, p.longitude);
      final anterior = _miPosicion;
      final dist = anterior == null
          ? 9999.0
          : haversineKm(anterior.latitude, anterior.longitude, nuevaPos.latitude, nuevaPos.longitude) *
              1000;
      final deltaRumbo = (rumbo.isFinite && rumbo >= 0 && _miRumbo != null)
          ? (rumbo - _miRumbo!).abs()
          : 9999.0;

      if (dist < 6 && deltaRumbo < 10) return;

      setState(() {
        _miPosicion = nuevaPos;
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
      final linea = await brouter.calcular(puntosRuta, perfil: _perfilRuta);
      estado.setTrazo(linea);
      _snack('Ruta ${_nombrePerfilRuta()}: ${estado.kilometros.toStringAsFixed(1)} km');
    } catch (e) {
      _snack('Error: ${e.toString()}');
    } finally {
      estado.setCalculando(false);
    }
  }

  void _abrirGestionPuntosRuta() {
    showModalBottomSheet<void>(
      context: context,
      builder: (c) => SafeArea(
        child: ListenableBuilder(
          listenable: estado,
          builder: (context, _) {
            if (estado.puntos.isEmpty) {
              return const Padding(
                padding: EdgeInsets.all(24),
                child: Text('No hay puntos de ruta.'),
              );
            }
            return FractionallySizedBox(
              heightFactor: 0.72,
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.swap_vert),
                    title: const Text('Invertir inicio y fin'),
                    subtitle: const Text('Invierte el orden de todos los puntos'),
                    onTap: estado.puntos.length < 2
                        ? null
                        : () {
                            estado.invertirPuntos();
                            _snack('Orden de puntos invertido');
                          },
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: ListView.builder(
                      itemCount: estado.puntos.length,
                      itemBuilder: (context, i) {
                        final p = estado.puntos[i];
                        final esInicio = i == 0;
                        final esFin = i == estado.puntos.length - 1;
                        final titulo = esInicio
                            ? 'Inicio'
                            : (esFin ? 'Fin' : 'Paso ${i + 1}');
                        return ListTile(
                          leading: Icon(
                            Icons.circle,
                            size: 14,
                            color: esInicio
                                ? Colors.green
                                : (esFin ? Colors.red : Colors.orange),
                          ),
                          title: Text(titulo),
                          subtitle: Text(
                            '${p.lat.toStringAsFixed(6)}, ${p.lon.toStringAsFixed(6)}',
                          ),
                          trailing: PopupMenuButton<String>(
                            onSelected: (v) {
                              if (v == 'inicio') {
                                estado.moverPuntoAInicio(i);
                                _snack('Punto movido a inicio');
                              } else if (v == 'fin') {
                                estado.moverPuntoAFin(i);
                                _snack('Punto movido a fin');
                              } else if (v == 'eliminar') {
                                estado.quitarPunto(i);
                                _snack('Punto eliminado');
                              }
                            },
                            itemBuilder: (context) => [
                              if (!esInicio)
                                const PopupMenuItem(
                                  value: 'inicio',
                                  child: Text('Poner como inicio'),
                                ),
                              if (!esFin)
                                const PopupMenuItem(
                                  value: 'fin',
                                  child: Text('Poner como fin'),
                                ),
                              const PopupMenuItem(
                                value: 'eliminar',
                                child: Text('Eliminar punto'),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  bool _tapSobreRuta(TapEvent ev) {
    final ruta = estado.trazo;
    if (ruta.length < 2) return false;
    final escala = MapsforgeSettingsMgr().getDeviceScaleFactor();
    final umbral = math.max(14.0 * escala, (_grosorRuta + 8) * escala);
    final px = ev.mappoint;

    for (var i = 0; i < ruta.length - 1; i++) {
      final a = ev.projection.latLonToPixel(ruta[i]);
      final b = ev.projection.latLonToPixel(ruta[i + 1]);
      final d = _distanciaPuntoASegmento(px.x, px.y, a.x, a.y, b.x, b.y);
      if (d <= umbral) return true;
    }
    return false;
  }

  double _distanciaPuntoASegmento(
    double px,
    double py,
    double ax,
    double ay,
    double bx,
    double by,
  ) {
    final abx = bx - ax;
    final aby = by - ay;
    final apx = px - ax;
    final apy = py - ay;
    final ab2 = abx * abx + aby * aby;
    if (ab2 <= 1e-9) {
      final dx = px - ax;
      final dy = py - ay;
      return math.sqrt(dx * dx + dy * dy);
    }
    var t = (apx * abx + apy * aby) / ab2;
    t = t.clamp(0.0, 1.0);
    final cx = ax + abx * t;
    final cy = ay + aby * t;
    final dx = px - cx;
    final dy = py - cy;
    return math.sqrt(dx * dx + dy * dy);
  }

  void _abrirTarjetaRuta() {
    if (_panelRutaAbierto || estado.trazo.length < 2) return;
    _panelRutaAbierto = true;
    showModalBottomSheet<void>(
      context: context,
      builder: (c) => SafeArea(
        child: StatefulBuilder(
          builder: (context, setModal) {
            return FractionallySizedBox(
              heightFactor: 0.62,
              child: ListView(
                children: [
                  ListTile(
                    leading: const Icon(Icons.route),
                    title: Text('Ruta activa (${estado.kilometros.toStringAsFixed(1)} km)'),
                    subtitle: Text('Perfil: ${_nombrePerfilRuta()}'),
                  ),
                  ListTile(
                    leading: const Icon(Icons.swap_vert),
                    title: const Text('Invertir inicio y fin'),
                    onTap: () {
                      estado.invertirPuntos();
                      Navigator.pop(c);
                      _snack('Orden de puntos invertido');
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.format_list_numbered),
                    title: const Text('Gestionar puntos de ruta'),
                    onTap: () {
                      Navigator.pop(c);
                      _abrirGestionPuntosRuta();
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.refresh),
                    title: const Text('Re-trazar ruta'),
                    onTap: () {
                      Navigator.pop(c);
                      unawaited(_trazarRuta());
                    },
                  ),
                  const Divider(height: 20),
                  const ListTile(
                    leading: Icon(Icons.straighten),
                    title: Text('Grosor de ruta'),
                  ),
                  Slider(
                    value: _grosorRuta,
                    min: 0.5,
                    max: 6.0,
                    divisions: 55,
                    label: _grosorRuta.toStringAsFixed(1),
                    onChanged: (v) {
                      setState(() => _grosorRuta = v);
                      setModal(() {});
                      unawaited(_guardarAjustesUI());
                    },
                  ),
                ],
              ),
            );
          },
        ),
      ),
    ).whenComplete(() {
      _panelRutaAbierto = false;
    });
  }

  String _nombrePerfilRuta() {
    for (final p in _perfilesRuta) {
      if (p.id == _perfilRuta) return p.nombre;
    }
    return _perfilRuta;
  }

  void _unToqueNorte() {
    _subBrujula?.cancel();
    _subBrujula = null;
    if (_orientacion == ModoOrientacion.norte) {
      setState(() => _orientacion = ModoOrientacion.libre);
      return;
    }
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

  Future<void> _compartir(Punto p) async {
    final texto = '${p.lat.toStringAsFixed(6)}, ${p.lon.toStringAsFixed(6)}';
    await SharePlus.instance.share(ShareParams(text: texto));
  }

  Future<void> _compartirMiUbicacion() async {
    final pos = await _posicionActual();
    if (pos == null) {
      _snack('No fue posible obtener la ubicación actual');
      return;
    }
    final p = Punto(pos.latitude, pos.longitude, 'Mi ubicación');
    await _compartir(p);
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
                  unawaited(_guardarAjustesUI());
                },
              );
            }

            return FractionallySizedBox(
              heightFactor: 0.85,
              child: ListView(
                shrinkWrap: true,
                children: [
                  const ListTile(
                    leading: Icon(Icons.tune),
                    title: Text('Ajuste de zoom al encuadrar'),
                  ),
                  ListTile(
                    leading: const Icon(Icons.alt_route),
                    title: const Text('Perfil de enrutamiento'),
                    subtitle: Text(_nombrePerfilRuta()),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: DropdownButtonFormField<String>(
                      initialValue: _perfilRuta,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      items: _perfilesRuta
                          .map((p) => DropdownMenuItem(value: p.id, child: Text(p.nombre)))
                          .toList(growable: false),
                      onChanged: (v) {
                        if (v == null) return;
                        setState(() => _perfilRuta = v);
                        setModal(() {});
                        unawaited(_guardarAjustesUI());
                      },
                    ),
                  ),
                  const Divider(height: 20),
                  opcion(AjusteFitZoom.cercano, 'Cercano', 'Zoom más alto al abrir capa/track'),
                  opcion(AjusteFitZoom.normal, 'Normal', 'Balance recomendado'),
                  opcion(AjusteFitZoom.amplio, 'Amplio', 'Muestra más contexto alrededor'),
                  const Divider(height: 20),
                  SwitchListTile(
                    secondary: const Icon(Icons.label_outline),
                    title: const Text('Mostrar etiquetas del mapa'),
                    subtitle: const Text('Desactívalo para mejorar rendimiento'),
                    value: _mostrarEtiquetas,
                    onChanged: (v) {
                      setState(() => _mostrarEtiquetas = v);
                      setModal(() {});
                      unawaited(_guardarAjustesUI());
                    },
                  ),
                  const Divider(height: 20),
                  const ListTile(
                    leading: Icon(Icons.place_outlined),
                    title: Text('Tamaño de puntos de referencia'),
                  ),
                  Slider(
                    value: _escalaPuntos,
                    min: 0.1,
                    max: 8.0,
                    divisions: 79,
                    label: _escalaPuntos.toStringAsFixed(1),
                    onChanged: (v) {
                      setState(() => _escalaPuntos = v);
                      setModal(() {});
                      unawaited(_guardarAjustesUI());
                    },
                  ),
                  const ListTile(
                    leading: Icon(Icons.my_location),
                    title: Text('Tamaño cursor de posición'),
                  ),
                  Slider(
                    value: _escalaPosicion,
                    min: 1.0,
                    max: 10.0,
                    divisions: 36,
                    label: _escalaPosicion.toStringAsFixed(1),
                    onChanged: (v) {
                      setState(() => _escalaPosicion = v);
                      setModal(() {});
                      unawaited(_guardarAjustesUI());
                    },
                  ),
                  const ListTile(
                    leading: Icon(Icons.timeline),
                    title: Text('Grosor track grabado'),
                  ),
                  Slider(
                    value: _grosorTrack,
                    min: 0.5,
                    max: 6.0,
                    divisions: 55,
                    label: _grosorTrack.toStringAsFixed(1),
                    onChanged: (v) {
                      setState(() => _grosorTrack = v);
                      setModal(() {});
                      unawaited(_guardarAjustesUI());
                    },
                  ),
                  const SizedBox(height: 12),
                ],
              ),
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

  Future<void> _cargarAjustesUI() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final guardado = prefs.getString(_prefAjusteFitZoom);
      _ajusteFitZoom = AjusteFitZoom.values.firstWhere(
        (v) => v.name == guardado,
        orElse: () => AjusteFitZoom.normal,
      );
      _escalaPuntos = prefs.getDouble(_prefEscalaPuntos) ?? 1.0;
      _escalaPosicion = prefs.getDouble(_prefEscalaPosicion) ?? 6.0;
      _grosorRuta = prefs.getDouble(_prefGrosorRuta) ?? 2.2;
      _grosorTrack = prefs.getDouble(_prefGrosorTrack) ?? 2.4;
      _mostrarEtiquetas = prefs.getBool(_prefMostrarEtiquetas) ?? true;
      _perfilRuta = prefs.getString(_prefPerfilRuta) ?? 'trekking';
      if (_perfilesRuta.every((p) => p.id != _perfilRuta)) {
        _perfilRuta = 'trekking';
      }
    } catch (_) {
      _ajusteFitZoom = AjusteFitZoom.normal;
      _escalaPuntos = 1.0;
      _escalaPosicion = 6.0;
      _grosorRuta = 2.2;
      _grosorTrack = 2.4;
      _mostrarEtiquetas = true;
      _perfilRuta = 'trekking';
    }
  }

  Future<void> _guardarAjustesUI() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefAjusteFitZoom, _ajusteFitZoom.name);
      await prefs.setDouble(_prefEscalaPuntos, _escalaPuntos);
      await prefs.setDouble(_prefEscalaPosicion, _escalaPosicion);
      await prefs.setDouble(_prefGrosorRuta, _grosorRuta);
      await prefs.setDouble(_prefGrosorTrack, _grosorTrack);
      await prefs.setBool(_prefMostrarEtiquetas, _mostrarEtiquetas);
      await prefs.setString(_prefPerfilRuta, _perfilRuta);
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

  List<DefaultHandler> _crearHandlers(MapModel modelo) {
    const t = 350;
    return [
      SingleTapHandler(longPressDuration: t, mapModel: modelo),
      LongTapHandler(longPressDuration: t, mapModel: modelo),
      DoubleTapHandler(longPressDuration: t, mapModel: modelo),
      DragNdropHandler(longPressDuration: t, mapModel: modelo),
      MoveHandler(longPressDuration: t, mapModel: modelo),
      RotationHandler(longPressDuration: t, mapModel: modelo, pointerCount: 2, thresholdDeg: 3),
      ScaleHandler(longPressDuration: t, mapModel: modelo),
    ];
  }

  /// Corrige un defecto de mapsforge_flutter 4.1.0: cuando un pellizco termina con un cambio
  /// de zoom menor a medio nivel, ScaleHandler llama a MapModel.zoomTo(zoomActual), que sale
  /// sin hacer nada porque el nivel es el mismo. El mapa queda con una escala fraccionaria
  /// (p. ej. 0.839) y la conversión toque -> coordenada de la librería ignora esa escala,
  /// así que los puntos caen desplazados respecto al dedo (más cuanto más lejos del centro).
  /// Al soltar todos los dedos se vuelve a escala 1 (misma posición, rotación y zoom).
  void _restablecerEscala(MapModel modelo) {
    // Se espera un instante para que ScaleHandler termine primero su propio cierre.
    Timer(const Duration(milliseconds: 60), () {
      if (!mounted || _punterosActivos != 0) return;
      final pos = modelo.lastPosition;
      if (pos == null || (pos.scale - 1).abs() < 1e-9) return;
      _diag('OffMaps ESCALA restablecida ${pos.scale.toStringAsFixed(3)} -> 1 '
          '(zoom ${pos.zoomlevel})');
      modelo.setPosition(pos.zoomTo(pos.zoomlevel));
    });
  }

  void _cancelarLongPress() {
    _temporizadorLongPress?.cancel();
    _temporizadorLongPress = null;
    _punteroLongPress = null;
    _inicioLongPress = null;
  }

  void _programarLongPress({
    required int puntero,
    required Offset offset,
    required Size size,
    required MapModel modelo,
  }) {
    _cancelarLongPress();
    _punteroLongPress = puntero;
    _inicioLongPress = offset;
    _temporizadorLongPress = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      if (_multitouchEnCurso || _punterosActivos != 1) return;
      final p = _inicioLongPress;
      if (p == null) return;
      _agregarPuntoDesdeToque(p, size, modelo);
      _cancelarLongPress();
    });
  }

  /// Convierte un punto de pantalla (dp) en coordenada, con la misma fórmula que usa la librería.
  LatLong _pantallaACoordenada(MapPosition pos, Offset offset, Size size) {
    final center = pos.getCenter();
    final scale = MapsforgeSettingsMgr().getDeviceScaleFactor();
    var diffX = (offset.dx - size.width / 2) * scale;
    var diffY = (offset.dy - size.height / 2) * scale;

    if (pos.rotation != 0) {
      final hyp = math.sqrt(diffX * diffX + diffY * diffY);
      final rad = math.atan2(diffY, diffX);
      final rot = pos.rotationRadian;
      diffX = math.cos(-rot + rad) * hyp;
      diffY = math.sin(-rot + rad) * hyp;
    }

    final ll = pos.projection.pixelToLatLong(center.x + diffX, center.y + diffY);
    return LatLong(ll.latitude, ll.longitude);
  }

  void _agregarPuntoDesdeToque(Offset offset, Size size, MapModel modelo) {
    final ahora = modelo.lastPosition;
    if (ahora == null) return;

    final alTocar = _posAlTocar;
    final offsetAlTocar = _offsetAlTocar;
    final llAhora = _pantallaACoordenada(ahora, offset, size);
    LatLong? llAlTocar;
    if (alTocar != null && offsetAlTocar != null) {
      llAlTocar = _pantallaACoordenada(alTocar, offsetAlTocar, size);
    }

    // ---- diagnóstico: ¿se movió el mapa entre poner el dedo y cumplirse la pulsación?
    if (diagnostico) {
      final dpr = MapsforgeSettingsMgr().getDeviceScaleFactor();
      String movimiento = 'sin dato';
      if (alTocar != null) {
        if (alTocar.zoomlevel != ahora.zoomlevel) {
          movimiento = 'zoom distinto (${alTocar.zoomlevel} -> ${ahora.zoomlevel})';
        } else {
          final c0 = alTocar.getCenter();
          final c1 = ahora.getCenter();
          final dx = c1.x - c0.x;
          final dy = c1.y - c0.y;
          movimiento = '${(math.sqrt(dx * dx + dy * dy) / dpr).toStringAsFixed(1)} px, '
              'giro ${(ahora.rotation - alTocar.rotation).toStringAsFixed(1)}°';
        }
      }
      final difMetros = llAlTocar == null
          ? null
          : haversineKm(llAhora.latitude, llAhora.longitude, llAlTocar.latitude, llAlTocar.longitude) * 1000;
      final pantalla = MediaQuery.sizeOf(context);
      _diag('OffMaps PUNTO zoom=${ahora.zoomlevel} scale=${ahora.scale.toStringAsFixed(3)} '
          'rot=${ahora.rotation.toStringAsFixed(1)} modo=$_orientacion dpr=${dpr.toStringAsFixed(2)} '
          'tamanoStack=${size.width.toStringAsFixed(0)}x${size.height.toStringAsFixed(0)} '
          'tamanoPantalla=${pantalla.width.toStringAsFixed(0)}x${pantalla.height.toStringAsFixed(0)} '
          'dedo=(${offset.dx.toStringAsFixed(0)},${offset.dy.toStringAsFixed(0)}) '
          'mapaSeMovio=$movimiento '
          'difAhoraVsAlTocar=${difMetros?.toStringAsFixed(1) ?? "?"} m '
          'ahora=(${llAhora.latitude.toStringAsFixed(6)},${llAhora.longitude.toStringAsFixed(6)}) '
          'alTocar=(${llAlTocar?.latitude.toStringAsFixed(6) ?? "?"},${llAlTocar?.longitude.toStringAsFixed(6) ?? "?"}) '
          'usado=${puntoConPosicionAlTocar && llAlTocar != null ? "alTocar" : "ahora"}');
    }

    final ll = (puntoConPosicionAlTocar && llAlTocar != null) ? llAlTocar : llAhora;
    estado.agregarPunto(ll.latitude, ll.longitude);
  }

  int? _indicePuntoCercanoTap(TapEvent ev) {
    if (estado.puntos.isEmpty) return null;
    final escala = MapsforgeSettingsMgr().getDeviceScaleFactor();
    final umbral = 24.0 * escala;
    var mejorIndice = -1;
    var mejorDist = double.infinity;

    for (var i = 0; i < estado.puntos.length; i++) {
      final p = estado.puntos[i];
      final px = ev.projection.latLonToPixel(LatLong(p.lat, p.lon));
      final dx = px.x - ev.mappoint.x;
      final dy = px.y - ev.mappoint.y;
      final d = math.sqrt(dx * dx + dy * dy);
      if (d < mejorDist) {
        mejorDist = d;
        mejorIndice = i;
      }
    }

    if (mejorIndice < 0 || mejorDist > umbral) return null;
    return mejorIndice;
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
                  builder: (context, _) => LayoutBuilder(
                    builder: (context, constraints) => Stack(
                      children: [
                        // gestos: un toque, doble toque, pulsación larga, mover, zoom, rotar
                        GenericGestureDetector(
                          mapModel: modelo,
                          handlers: _crearHandlers(modelo),
                        ),
                        Positioned.fill(
                          child: Listener(
                            behavior: HitTestBehavior.translucent,
                            onPointerDown: (e) {
                              if (_punterosActivos == 0) {
                                _posAlTocar = modelo.lastPosition;
                                _offsetAlTocar = e.localPosition;
                              }
                              _punterosActivos++;
                              if (_punterosActivos > 1) {
                                _multitouchEnCurso = true;
                                _cancelarLongPress();
                              } else {
                                _programarLongPress(
                                  puntero: e.pointer,
                                  offset: e.localPosition,
                                  size: constraints.biggest,
                                  modelo: modelo,
                                );
                              }
                            },
                            onPointerMove: (e) {
                              if (_punteroLongPress != e.pointer || _inicioLongPress == null) return;
                              final d = e.localPosition - _inicioLongPress!;
                              if (d.distance > 18) _cancelarLongPress();
                            },
                            onPointerUp: (e) {
                              if (_punteroLongPress == e.pointer) _cancelarLongPress();
                              if (_punterosActivos > 0) _punterosActivos--;
                              if (_punterosActivos == 0) {
                                _multitouchEnCurso = false;
                                _restablecerEscala(modelo);
                              }
                            },
                            onPointerCancel: (e) {
                              if (_punteroLongPress == e.pointer) _cancelarLongPress();
                              if (_punterosActivos > 0) _punterosActivos--;
                              if (_punterosActivos == 0) {
                                _multitouchEnCurso = false;
                                _restablecerEscala(modelo);
                              }
                            },
                            child: const SizedBox.expand(),
                          ),
                        ),
                        ...modelo.renderers
                            .map((r) => TileView(mapModel: modelo, renderer: r)),
                        if (_mostrarEtiquetas && zoomActual >= 16)
                          ...modelo.labelRenderers
                              .map((r) => LabelView(mapModel: modelo, renderer: r)),
                        MarkerDatastoreOverlay(
                          mapModel: modelo,
                          datastore: _construirMarcadores(),
                          zoomlevelRange: ZoomlevelRange.standard(),
                        ),
                        if (zoomActual >= 14) DistanceOverlay(mapModel: modelo),
                        _badgeTrack(),
                        _botonesLaterales(modelo),
                      ],
                    ),
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
      ds.addMarker(IconMarker(
        latLong: p,
        iconData: Icons.my_location_rounded,
        size: _tamIconoPosicion(zoom),
        bitmapColor: 0xFF1976D2,
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
      final esFin = i == estado.puntos.length - 1;
      final color = esInicio
          ? 0xFF2E7D32
          : (esFin ? 0xFFD32F2F : 0xFFFF8F00);
      ds.addMarker(CircleMarker(
        latLong: LatLong(p.lat, p.lon),
        radius: _tamIconoPunto(zoom, base: 24, maximo: 34) * 0.35,
        fillColor: color,
        strokeColor: 0x66FFFFFF,
        strokeWidth: 0.8,
      ));
    }
    if (estado.trazo.length > 1) {
      ds.addMarker(PolylineMarker(
        path: List<LatLong>.from(estado.trazo),
        strokeWidth: _grosorRuta,
        strokeColor: 0xFF0B7A3E,
      ));
    }
    if (estado.trackActual.length > 1) {
      ds.addMarker(PolylineMarker(
        path: List<LatLong>.from(estado.trackActual),
        strokeWidth: _grosorTrack,
        strokeColor: estado.trackEnPausa ? 0xFFFFA000 : 0xFFD32F2F,
      ));
    }
    return ds;
  }

  double _tamIconoPunto(int zoom, {required double base, required double maximo}) {
    final t = ((15 - zoom) / 8).clamp(0.0, 1.0);
    return (base + (maximo - base) * t) * _escalaPuntos;
  }

  double _tamIconoPosicion(int zoom) {
    if (zoom >= 19) return 10 * _escalaPosicion;
    if (zoom >= 17) return 11 * _escalaPosicion;
    if (zoom >= 15) return 12 * _escalaPosicion;
    if (zoom >= 13) return 14 * _escalaPosicion;
    return 16 * _escalaPosicion;
  }

  double _tamIconoRumbo(int zoom) {
    final f = (_escalaPosicion / 6.0).clamp(0.4, 2.0);
    if (zoom >= 19) return 13 * f;
    if (zoom >= 17) return 15 * f;
    if (zoom >= 15) return 17 * f;
    if (zoom >= 13) return 20 * f;
    return 24 * f;
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
              icono: _importando ? Icons.hourglass_top : Icons.layers,
              onTap: _importando ? null : _importarCapa,
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
            _BotonIcono(
              icono: Icons.share,
              onTap: () {
                if (estado.puntos.isNotEmpty) {
                  unawaited(_compartir(estado.puntos.last));
                } else {
                  unawaited(_compartirMiUbicacion());
                }
              },
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
              icono: estado.calculando ? Icons.hourglass_top : Icons.route,
              onTap: estado.calculando ? null : _trazarRuta,
            ),
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
