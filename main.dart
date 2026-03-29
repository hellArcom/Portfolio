import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sqflite/sqflite.dart';

void main() {
  runApp(const AltisMapApp());
}

class AltisMapApp extends StatelessWidget {
  const AltisMapApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Altis Map Offline',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.light,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.teal,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      themeMode: ThemeMode.system,
      home: const MapHomeScreen(),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Écran principal
// ─────────────────────────────────────────────────────────────────────────────

class MapHomeScreen extends StatefulWidget {
  const MapHomeScreen({super.key});

  @override
  State<MapHomeScreen> createState() => _MapHomeScreenState();
}

class _MapHomeScreenState extends State<MapHomeScreen> {
  bool _isGpsActive = false;
  String _gpsAccuracy = '--';
  MapLibreMapController? _mapController;
  String? _mapStyleString;
  bool _isMapLoading = true;

  // Calques
  bool _showHillshade = true;
  bool _showContours = false;
  double _hillshadeOpacity = 0.5;
  bool _isSatelliteView = false;

  // Toutes les tuiles détectées, avec leurs bounds lus depuis les métadonnées
  // Chaque entrée : {'path': String, 'bounds': List<double>? [w,s,e,n], 'isTerrain': bool}
  List<Map<String, dynamic>> _vectorTiles = [];
  List<Map<String, dynamic>> _terrainTiles = [];

  // Conservé pour la compatibilité avec _selectVectorFile (gestionnaire)
  String? _vectorMapPath;

  CameraPosition? _currentCamera;
  LatLngBounds? _currentBounds;

  @override
  void initState() {
    super.initState();
    _loadOfflineMap();
  }

  // ── Chargement des tuiles ─────────────────────────────────────────────────

  /// Retourne le répertoire racine où les cartes sont stockées.
  Future<Directory> _getMapsDirectory() async {
    final dir = await getApplicationDocumentsDirectory();
    final mapsDir = Directory('${dir.path}/maps');
    if (!await mapsDir.exists()) {
      await mapsDir.create(recursive: true);
    }
    return mapsDir;
  }

  /// Parcours récursif : renvoie tous les .mbtiles trouvés dans [dir].
  List<File> _findMbtilesRecursive(Directory dir) {
    final result = <File>[];
    try {
      for (final entity in dir.listSync(recursive: true)) {
        if (entity is File && entity.path.endsWith('.mbtiles')) {
          result.add(entity);
        }
      }
    } catch (_) {}
    return result;
  }

  // ── Lecture des métadonnées MBTiles ──────────────────────────────────────

  /// Lit les bounds depuis la table metadata d'un fichier .mbtiles.
  /// Retourne [west, south, east, north] ou null si absent.
  Future<List<double>?> _readMbtilesBounds(String path) async {
    Database? db;
    try {
      db = await openDatabase(path, readOnly: true);
      final rows = await db.rawQuery(
        "SELECT value FROM metadata WHERE name = 'bounds' LIMIT 1",
      );
      if (rows.isNotEmpty) {
        final raw = rows.first['value'] as String?;
        if (raw != null) {
          final parts = raw.split(',').map((s) => double.tryParse(s.trim())).toList();
          if (parts.length == 4 && parts.every((v) => v != null)) {
            return parts.cast<double>();
          }
        }
      }
    } catch (e) {
      debugPrint('MBTiles metadata error ($path): $e');
    } finally {
      await db?.close();
    }
    return null;
  }

  /// Scanne tous les .mbtiles et lit leurs bounds réels.
  Future<void> _loadOfflineMap() async {
    setState(() => _isMapLoading = true);

    final mapsDir = await _getMapsDirectory();
    final files = _findMbtilesRecursive(mapsDir);

    final vectors = <Map<String, dynamic>>[];
    final terrains = <Map<String, dynamic>>[];

    for (final file in files) {
      final isTerrain =
          file.path.contains('terrain') || file.path.contains('dem');
      // Lecture des bounds (peut prendre quelques ms par fichier)
      final bounds = await _readMbtilesBounds(file.path);
      final entry = {
        'path': file.path,
        'bounds': bounds, // null si métadonnée absente
        'isTerrain': isTerrain,
      };
      if (isTerrain) {
        terrains.add(entry);
      } else {
        vectors.add(entry);
      }
    }

    _vectorTiles = vectors;
    _terrainTiles = terrains;

    // Pour la rétrocompatibilité avec _selectVectorFile
    if (_vectorMapPath == null && vectors.isNotEmpty) {
      _vectorMapPath = vectors.first['path'] as String;
    }

    await _updateMapStyle();
    setState(() => _isMapLoading = false);
  }

  /// Sélectionne explicitement un fichier vecteur (depuis le gestionnaire).
  Future<void> _selectVectorFile(String path) async {
    setState(() => _vectorMapPath = path);
    // On recharge complètement pour mettre à jour les bounds
    await _loadOfflineMap();
  }

  // ── Construction du style MapLibre ───────────────────────────────────────

  /// Génère les couches vectorielles pour un sourceId donné.
  /// Chaque fichier MBTiles obtient son propre jeu de couches avec un suffixe unique.
  List<Map<String, dynamic>> _buildLayersForSource(String sourceId) {
    final suffix = sourceId; // ex: "src-0", "src-1"
    final List<Map<String, dynamic>> layers = [];

    if (!_isSatelliteView) {
      layers.addAll([
        {
          'id': 'land-sb-$suffix',
          'type': 'fill',
          'source': sourceId,
          'source-layer': 'land',
          'maxzoom': 22,
          'paint': {'fill-color': '#f0ede5'},
        },
        {
          'id': 'landuse-sb-$suffix',
          'type': 'fill',
          'source': sourceId,
          'source-layer': 'landuse',
          'maxzoom': 22,
          'paint': {
            'fill-color': [
              'match', ['get', 'kind'],
              ['forest', 'wood', 'nature_reserve'], '#b5d29f',
              ['grass', 'meadow', 'park', 'allotments'], '#c3d9ad',
              '#e0dcd0',
            ],
            'fill-opacity': 0.8,
          },
        },
        {
          'id': 'ocean-sb-$suffix',
          'type': 'fill',
          'source': sourceId,
          'source-layer': 'ocean',
          'maxzoom': 22,
          'paint': {'fill-color': '#9bbff2'},
        },
        {
          'id': 'sites-sb-$suffix',
          'type': 'fill',
          'source': sourceId,
          'source-layer': 'sites',
          'maxzoom': 22,
          'paint': {
            'fill-color': [
              'match', ['get', 'kind'],
              'park', '#c3d9ad',
              'hospital', '#ffe5e5',
              'industrial', '#e8e8e8',
              'school', '#f0e6d2',
              '#e0e0e0',
            ],
            'fill-opacity': 0.4,
          },
        },
      ]);
    }

    layers.addAll([
      {
        'id': 'water-sb-$suffix',
        'type': 'fill',
        'source': sourceId,
        'source-layer': 'water_polygons',
        'maxzoom': 22,
        'paint': {
          'fill-color': _isSatelliteView ? 'rgba(0,0,0,0)' : '#a0c8f0',
        },
      },
      {
        'id': 'water-omt-$suffix',
        'type': 'fill',
        'source': sourceId,
        'source-layer': 'water',
        'maxzoom': 22,
        'paint': {
          'fill-color': _isSatelliteView ? 'rgba(0,0,0,0)' : '#a0c8f0',
        },
      },
      {
        'id': 'water-lines-sb-$suffix',
        'type': 'line',
        'source': sourceId,
        'source-layer': 'water_lines',
        'maxzoom': 22,
        'paint': {'line-color': '#a0c8f0', 'line-width': 1.5},
      },
      {
        'id': 'water-lines-omt-$suffix',
        'type': 'line',
        'source': sourceId,
        'source-layer': 'waterway',
        'maxzoom': 22,
        'paint': {'line-color': '#a0c8f0', 'line-width': 1.5},
      },
      {
        'id': 'boundaries-sb-$suffix',
        'type': 'line',
        'source': sourceId,
        'source-layer': 'boundaries',
        'maxzoom': 22,
        'paint': {
          'line-color': '#888888',
          'line-width': 1.0,
          'line-dasharray': [2, 2],
        },
      },
      {
        'id': 'street-polygons-sb-$suffix',
        'type': 'fill',
        'source': sourceId,
        'source-layer': 'street_polygons',
        'maxzoom': 22,
        'paint': {'fill-color': '#ffffff', 'fill-opacity': 0.5},
        'layout': {'visibility': _isSatelliteView ? 'none' : 'visible'},
      },
      {
        'id': 'roads-omt-$suffix',
        'type': 'line',
        'source': sourceId,
        'source-layer': 'transportation',
        'maxzoom': 22,
        'paint': {
          'line-color': '#ffffff',
          'line-width': [
            'interpolate', ['linear'], ['zoom'],
            8, 0.5, 14, 3.0, 18, 6.0,
          ],
          'line-opacity': _isSatelliteView ? 0.7 : 1.0,
        },
      },
      {
        'id': 'roads-sb-$suffix',
        'type': 'line',
        'source': sourceId,
        'source-layer': 'streets',
        'maxzoom': 22,
        'paint': {
          'line-color': _isSatelliteView ? '#ffeb3b' : '#fefefe',
          'line-width': [
            'interpolate', ['linear'], ['zoom'],
            8, 0.5, 14, 3.0, 18, 6.0,
          ],
          'line-opacity': _isSatelliteView ? 0.7 : 1.0,
        },
      },
      {
        'id': 'buildings-omt-$suffix',
        'type': 'fill',
        'source': sourceId,
        'source-layer': 'building',
        'maxzoom': 22,
        'paint': {'fill-color': '#d0d0d0', 'fill-opacity': 0.5},
        'layout': {'visibility': _isSatelliteView ? 'none' : 'visible'},
      },
      {
        'id': 'buildings-sb-$suffix',
        'type': 'fill',
        'source': sourceId,
        'source-layer': 'buildings',
        'maxzoom': 22,
        'paint': {'fill-color': '#a0a0a0', 'fill-opacity': 0.6},
        'layout': {'visibility': _isSatelliteView ? 'none' : 'visible'},
      },
      {
        'id': 'aerialways-sb-$suffix',
        'type': 'line',
        'source': sourceId,
        'source-layer': 'aerialways',
        'maxzoom': 22,
        'paint': {'line-color': '#666666', 'line-width': 1.0},
      },
      {
        'id': 'ferries-sb-$suffix',
        'type': 'line',
        'source': sourceId,
        'source-layer': 'ferries',
        'maxzoom': 22,
        'paint': {
          'line-color': '#a0c8f0',
          'line-width': 1.5,
          'line-dasharray': [4, 2],
        },
      },
    ]);

    if (_showContours) {
      layers.add({
        'id': 'contours-$suffix',
        'type': 'line',
        'source': sourceId,
        'source-layer': 'contour',
        'maxzoom': 22,
        'paint': {
          'line-color': '#888888',
          'line-width': 1.0,
          'line-opacity': 0.5,
        },
      });
    }

    return layers;
  }

  /// Reconstruit le style JSON avec UNE SOURCE PAR FICHIER .mbtiles.
  /// MapLibre charge automatiquement la bonne source selon la zone visible —
  /// aucune logique de sélection manuelle nécessaire.
  Future<void> _updateMapStyle() async {
    if (_vectorTiles.isEmpty) {
      if (mounted) setState(() => _mapStyleString = null);
      return;
    }

    final Map<String, dynamic> sources = {};
    final List<Map<String, dynamic>> layers = [
      {
        'id': 'background',
        'type': 'background',
        'paint': {
          'background-color': _isSatelliteView ? '#000000' : '#f0ede5',
        },
      },
    ];

    // Mode satellite
    if (_isSatelliteView) {
      sources['satellite-source'] = {
        'type': 'raster',
        'tiles': [
          'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
        ],
        'tileSize': 256,
      };
      layers.add({
        'id': 'satellite',
        'type': 'raster',
        'source': 'satellite-source',
      });
    }

    // ── UNE SOURCE PAR FICHIER VECTEUR ──
    // MapLibre gère nativement les bounds de chaque source MBTiles :
    // seules les tuiles dans la zone visible sont téléchargées/lues.
    for (int i = 0; i < _vectorTiles.length; i++) {
      final tile = _vectorTiles[i];
      final path = tile['path'] as String;
      final bounds = tile['bounds'] as List<double>?;
      final sourceId = 'vec-$i';

      final Map<String, dynamic> source = {
        'type': 'vector',
        'url': 'mbtiles://$path',
        'minzoom': 0,
        // maxzoom intentionnellement absent : lu depuis les métadonnées MBTiles
        // → overzoom automatique jusqu'au zoom 22.
      };

      // Si on a les bounds réels, on les transmet pour que MapLibre
      // évite de chercher des tuiles hors zone (élimine les rectangles vides).
      if (bounds != null) {
        source['bounds'] = bounds; // [west, south, east, north]
      }

      sources[sourceId] = source;
      layers.addAll(_buildLayersForSource(sourceId));
    }

    // ── TERRAIN DEM ──
    // Même logique : une source par fichier terrain.
    // On prend le premier terrain disponible pour le hillshade.
    if (_showHillshade && _terrainTiles.isNotEmpty) {
      final terrainPath = _terrainTiles.first['path'] as String;
      final terrainUrl = terrainPath.startsWith('/')
          ? 'mbtiles://$terrainPath'
          : 'mbtiles:///$terrainPath';
      sources['terrain-source'] = {
        'type': 'raster-dem',
        'url': terrainUrl,
        'tileSize': 256,
        'encoding': 'mapbox',
      };
      layers.add({
        'id': 'hillshade',
        'type': 'hillshade',
        'source': 'terrain-source',
        'paint': {
          'hillshade-exaggeration': 0.8,
          'hillshade-shadow-color': '#444444',
          'hillshade-highlight-color': '#ffffff',
          'hillshade-accent-color': '#000000',
          'hillshade-opacity':
              _isSatelliteView ? _hillshadeOpacity * 0.5 : _hillshadeOpacity,
        },
      });
    }

    final Map<String, dynamic> style = {
      'version': 8,
      'sources': sources,
      'layers': layers,
    };

    if (_showHillshade && _terrainTiles.isNotEmpty) {
      style['terrain'] = {'source': 'terrain-source', 'exaggeration': 1.5};
    }

    if (mounted) {
      setState(() => _mapStyleString = jsonEncode(style));
    }
  }

  // ── Chargement dynamique des tuiles selon la vue ──────────────────────────

  /// Appelé à chaque fin de mouvement de caméra.
  /// Avec le système multi-sources, MapLibre gère tout automatiquement.
  /// On conserve juste la mise à jour des bounds courants.
  Future<void> _onCameraIdle() async {
    if (_mapController == null) return;
    final bounds = await _mapController!.getVisibleRegion();
    if (mounted) setState(() => _currentBounds = bounds);
  }



  // ── GPS ───────────────────────────────────────────────────────────────────

  Future<void> _toggleGps() async {
    if (!_isGpsActive) {
      final status = await Permission.location.request();
      if (!status.isGranted) return;

      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Activez le GPS dans les paramètres.')),
          );
        }
        return;
      }

      setState(() => _isGpsActive = true);

      try {
        final position = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high,
        );
        _mapController?.animateCamera(
          CameraUpdate.newCameraPosition(
            CameraPosition(
              target: LatLng(position.latitude, position.longitude),
              zoom: 14.0,
            ),
          ),
        );
        setState(() => _gpsAccuracy = position.accuracy.toStringAsFixed(0));
      } catch (e) {
        debugPrint('Erreur GPS: $e');
      }
    } else {
      setState(() {
        _isGpsActive = false;
        _gpsAccuracy = '--';
      });
    }
  }

  // ── Calques ───────────────────────────────────────────────────────────────

  void _showLayerSettings(BuildContext context) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => StatefulBuilder(
        builder: (context, setModalState) => Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: Colors.grey[400],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const Text(
                'Calques de carte',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                title: const Text('Mode Satellite (en ligne)'),
                value: _isSatelliteView,
                onChanged: (val) {
                  setModalState(() => _isSatelliteView = val);
                  setState(() => _isSatelliteView = val);
                  _updateMapStyle();
                },
              ),
              SwitchListTile(
                title: const Text('Relief (Hillshade)'),
                subtitle: _terrainTiles.isEmpty
                    ? const Text(
                        'Aucun fichier DEM trouvé',
                        style: TextStyle(color: Colors.red, fontSize: 12),
                      )
                    : null,
                value: _showHillshade,
                onChanged: _terrainTiles.isEmpty
                    ? null
                    : (val) {
                        setModalState(() => _showHillshade = val);
                        setState(() => _showHillshade = val);
                        _updateMapStyle();
                      },
              ),
              if (_showHillshade && _terrainTiles.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      const Text('Opacité du relief'),
                      Expanded(
                        child: Slider(
                          value: _hillshadeOpacity,
                          min: 0.0,
                          max: 1.0,
                          divisions: 10,
                          label: '${(_hillshadeOpacity * 100).round()}%',
                          onChanged: (val) {
                            setModalState(() => _hillshadeOpacity = val);
                            setState(() => _hillshadeOpacity = val);
                            _updateMapStyle();
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              SwitchListTile(
                title: const Text('Courbes de niveau'),
                value: _showContours,
                onChanged: (val) {
                  setModalState(() => _showContours = val);
                  setState(() => _showContours = val);
                  _updateMapStyle();
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const Text('Altis Map'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        flexibleSpace: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.black.withOpacity(0.6), Colors.transparent],
            ),
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.layers, color: Colors.white),
            tooltip: 'Calques',
            onPressed: () => _showLayerSettings(context),
          ),
          IconButton(
            icon: const Icon(Icons.folder_open, color: Colors.white),
            tooltip: 'Gérer les cartes',
            onPressed: () async {
              final result = await Navigator.push<Map<String, dynamic>>(
                context,
                MaterialPageRoute(
                  builder: (_) => const OfflineManagerScreen(),
                ),
              );
              if (result != null) {
                final filePath = result['filePath'] as String?;
                if (filePath != null) {
                  await _selectVectorFile(filePath);
                }
                // Dessiner les bounds si présents
                final bounds = result['bounds'] as List<LatLng>?;
                if (bounds != null && bounds.isNotEmpty) {
                  _fitBounds(bounds);
                }
              } else {
                // Rechargement automatique en cas de nouveau téléchargement
                await _loadOfflineMap();
              }
            },
          ),
        ],
        iconTheme: const IconThemeData(color: Colors.white),
        titleTextStyle: const TextStyle(color: Colors.white, fontSize: 20),
      ),
      body: Stack(
        children: [
          // ── Carte ──────────────────────────────────────────────────────
          if (_mapStyleString != null)
            Positioned.fill(
              child: MapLibreMap(
                key: ValueKey('map_${_vectorTiles.length}_${_mapStyleString.hashCode}'),
                onMapCreated: (controller) {
                  setState(() => _mapController = controller);
                },
                onCameraIdle: _onCameraIdle,
                styleString: _mapStyleString!,
                initialCameraPosition: const CameraPosition(
                  target: LatLng(46.603354, 1.888334),
                  zoom: 6.0,
                ),
                myLocationEnabled: _isGpsActive,
                myLocationRenderMode: MyLocationRenderMode.normal,
                trackCameraPosition: true,
              ),
            )
          else
            Container(
              color: const Color(0xFFE0E0E0),
              child: Center(
                child: _isMapLoading
                    ? const CircularProgressIndicator()
                    : Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.map_outlined,
                              size: 64, color: Colors.grey),
                          const SizedBox(height: 16),
                          const Text(
                            'Aucune carte disponible.\nTéléchargez-en une via l\'icône dossier.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.grey),
                          ),
                          const SizedBox(height: 24),
                          ElevatedButton.icon(
                            icon: const Icon(Icons.folder_open),
                            label: const Text('Gérer les cartes'),
                            onPressed: () async {
                              final result =
                                  await Navigator.push<Map<String, dynamic>>(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => const OfflineManagerScreen(),
                                ),
                              );
                              if (result != null) {
                                final filePath = result['filePath'] as String?;
                                if (filePath != null) {
                                  await _selectVectorFile(filePath);
                                }
                              } else {
                                await _loadOfflineMap();
                              }
                            },
                          ),
                        ],
                      ),
              ),
            ),

          // ── Chip précision GPS ─────────────────────────────────────────
          if (_isGpsActive && _mapStyleString != null)
            Positioned(
              top: kToolbarHeight + MediaQuery.of(context).padding.top + 8,
              left: 16,
              child: Chip(
                avatar: const Icon(Icons.my_location, size: 14),
                label: Text('GPS ±$_gpsAccuracy m'),
                backgroundColor:
                    Theme.of(context).colorScheme.surface.withOpacity(0.9),
                labelStyle: const TextStyle(fontSize: 12),
                padding: EdgeInsets.zero,
              ),
            ),

          // ── Contrôles zoom + GPS ───────────────────────────────────────
          Positioned(
            bottom: 32,
            right: 16,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _MapButton(
                  icon: Icons.add,
                  heroTag: 'zoom_in',
                  onPressed: () =>
                      _mapController?.animateCamera(CameraUpdate.zoomIn()),
                ),
                const SizedBox(height: 8),
                _MapButton(
                  icon: Icons.remove,
                  heroTag: 'zoom_out',
                  onPressed: () =>
                      _mapController?.animateCamera(CameraUpdate.zoomOut()),
                ),
                const SizedBox(height: 24),
                FloatingActionButton(
                  heroTag: 'gps_btn',
                  backgroundColor:
                      _isGpsActive ? Colors.blue : null,
                  onPressed: _toggleGps,
                  child: Icon(
                    _isGpsActive ? Icons.gps_fixed : Icons.gps_not_fixed,
                    color: _isGpsActive ? Colors.white : null,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Utilitaires ───────────────────────────────────────────────────────────

  void _fitBounds(List<LatLng> points) {
    if (_mapController == null || points.isEmpty) return;
    final lats = points.map((p) => p.latitude);
    final lngs = points.map((p) => p.longitude);
    _mapController!.animateCamera(
      CameraUpdate.newLatLngBounds(
        LatLngBounds(
          southwest: LatLng(lats.reduce((a, b) => a < b ? a : b),
              lngs.reduce((a, b) => a < b ? a : b)),
          northeast: LatLng(lats.reduce((a, b) => a > b ? a : b),
              lngs.reduce((a, b) => a > b ? a : b)),
        ),
        left: 40,
        top: kToolbarHeight + 80,
        right: 40,
        bottom: 40,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Widget bouton carte compact
// ─────────────────────────────────────────────────────────────────────────────

class _MapButton extends StatelessWidget {
  final IconData icon;
  final String heroTag;
  final VoidCallback onPressed;

  const _MapButton({
    required this.icon,
    required this.heroTag,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return FloatingActionButton.small(
      heroTag: heroTag,
      onPressed: onPressed,
      child: Icon(icon),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Gestionnaire de cartes hors-ligne
// ─────────────────────────────────────────────────────────────────────────────

class OfflineManagerScreen extends StatefulWidget {
  const OfflineManagerScreen({super.key});

  @override
  State<OfflineManagerScreen> createState() => _OfflineManagerScreenState();
}

class _OfflineManagerScreenState extends State<OfflineManagerScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cartes hors-ligne'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(icon: Icon(Icons.folder), text: 'Mes cartes'),
            Tab(icon: Icon(Icons.download), text: 'Télécharger'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: const [
          _LocalFilesView(),
          _RemoteDownloadView(),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Onglet 1 : arborescence des fichiers locaux
// ─────────────────────────────────────────────────────────────────────────────

class _LocalFilesView extends StatefulWidget {
  const _LocalFilesView();

  @override
  State<_LocalFilesView> createState() => _LocalFilesViewState();
}

class _LocalFilesViewState extends State<_LocalFilesView> {
  Directory? _mapsDir;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/maps');
    if (!await dir.exists()) await dir.create(recursive: true);
    setState(() {
      _mapsDir = dir;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_mapsDir == null) return const SizedBox.shrink();

    return _DirectoryTree(
      directory: _mapsDir!,
      onFileSelected: (file) {
        Navigator.of(context).pop({'filePath': file.path, 'bounds': <LatLng>[]});
      },
      onFileDeleted: () => setState(() {}),
    );
  }
}

// ── Arborescence récursive ────────────────────────────────────────────────────

class _DirectoryTree extends StatefulWidget {
  final Directory directory;
  final void Function(File) onFileSelected;
  final VoidCallback onFileDeleted;
  final int depth;

  const _DirectoryTree({
    required this.directory,
    required this.onFileSelected,
    required this.onFileDeleted,
    this.depth = 0,
  });

  @override
  State<_DirectoryTree> createState() => _DirectoryTreeState();
}

class _DirectoryTreeState extends State<_DirectoryTree> {
  List<FileSystemEntity> _entities = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final entities = widget.directory.listSync()
        ..sort((a, b) {
          // Dossiers avant fichiers, puis par nom
          final aIsDir = a is Directory;
          final bIsDir = b is Directory;
          if (aIsDir != bIsDir) return aIsDir ? -1 : 1;
          return a.path
              .split(Platform.pathSeparator)
              .last
              .compareTo(b.path.split(Platform.pathSeparator).last);
        });
      setState(() {
        _entities = entities;
        _loading = false;
      });
    } catch (e) {
      setState(() => _loading = false);
    }
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: CircularProgressIndicator(),
      );
    }

    if (_entities.isEmpty) {
      return Padding(
        padding: EdgeInsets.only(
            left: 16.0 + widget.depth * 16, top: 8, bottom: 8),
        child: Text(
          'Aucun fichier',
          style: TextStyle(color: Colors.grey[500], fontStyle: FontStyle.italic),
        ),
      );
    }

    return ListView.builder(
      shrinkWrap: true,
      physics: widget.depth == 0
          ? const AlwaysScrollableScrollPhysics()
          : const NeverScrollableScrollPhysics(),
      itemCount: _entities.length,
      itemBuilder: (context, i) {
        final entity = _entities[i];
        final name = entity.path.split(Platform.pathSeparator).last;
        final indent = widget.depth * 16.0;

        if (entity is Directory) {
          return _ExpandableFolder(
            name: name,
            directory: entity,
            indent: indent,
            onFileSelected: widget.onFileSelected,
            onFileDeleted: () {
              _load();
              widget.onFileDeleted();
            },
          );
        }

        if (entity is File) {
          final isMbtiles = name.endsWith('.mbtiles');
          final size = entity.lengthSync();
          return ListTile(
            contentPadding: EdgeInsets.only(left: 16 + indent, right: 8),
            leading: Icon(
              isMbtiles ? Icons.map : Icons.insert_drive_file,
              color: isMbtiles ? Colors.teal : Colors.grey,
            ),
            title: Text(name, style: const TextStyle(fontSize: 14)),
            subtitle: Text(_formatSize(size),
                style: const TextStyle(fontSize: 12)),
            trailing: isMbtiles
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.check_circle_outline,
                            color: Colors.teal),
                        tooltip: 'Utiliser cette carte',
                        onPressed: () => widget.onFileSelected(entity),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline,
                            color: Colors.red),
                        tooltip: 'Supprimer',
                        onPressed: () async {
                          final confirmed = await _confirmDelete(context, name);
                          if (confirmed == true) {
                            await entity.delete();
                            _load();
                            widget.onFileDeleted();
                          }
                        },
                      ),
                    ],
                  )
                : null,
          );
        }

        return const SizedBox.shrink();
      },
    );
  }

  Future<bool?> _confirmDelete(BuildContext context, String name) {
    return showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Supprimer'),
        content: Text('Voulez-vous supprimer "$name" ?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annuler'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
  }
}

class _ExpandableFolder extends StatefulWidget {
  final String name;
  final Directory directory;
  final double indent;
  final void Function(File) onFileSelected;
  final VoidCallback onFileDeleted;

  const _ExpandableFolder({
    required this.name,
    required this.directory,
    required this.indent,
    required this.onFileSelected,
    required this.onFileDeleted,
  });

  @override
  State<_ExpandableFolder> createState() => _ExpandableFolderState();
}

class _ExpandableFolderState extends State<_ExpandableFolder> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          contentPadding: EdgeInsets.only(left: 16 + widget.indent),
          leading: Icon(
            _expanded ? Icons.folder_open : Icons.folder,
            color: Colors.amber[700],
          ),
          title: Text(widget.name,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          trailing: Icon(
              _expanded ? Icons.expand_less : Icons.expand_more),
          onTap: () => setState(() => _expanded = !_expanded),
        ),
        if (_expanded)
          Padding(
            padding: const EdgeInsets.only(left: 16),
            child: _DirectoryTree(
              directory: widget.directory,
              onFileSelected: widget.onFileSelected,
              onFileDeleted: widget.onFileDeleted,
              depth: 1,
            ),
          ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Onglet 2 : téléchargement depuis Geofabrik
// ─────────────────────────────────────────────────────────────────────────────

class _RemoteDownloadView extends StatefulWidget {
  const _RemoteDownloadView();

  @override
  State<_RemoteDownloadView> createState() => _RemoteDownloadViewState();
}

class _RemoteDownloadViewState extends State<_RemoteDownloadView> {
  /// URL configurable (peut devenir un champ de saisie)
  final String _baseUrl = 'https://download.geofabrik.de/europe/france/';
  final Dio _dio = Dio();

  List<_RemoteMap> _maps = [];
  bool _isLoading = true;
  String? _errorMessage;
  final Map<String, double> _downloadProgress = {};
  Set<String> _downloadedFiles = {};

  @override
  void initState() {
    super.initState();
    _fetchRemoteMaps();
  }

  Future<Directory> _getMapsDirectory() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/maps');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<void> _refreshDownloadedFiles() async {
    final dir = await _getMapsDirectory();
    final files = dir.listSync(recursive: true).whereType<File>().toList();
    setState(() {
      _downloadedFiles = files
          .map((f) => f.path.split(Platform.pathSeparator).last)
          .toSet();
    });
  }

  /// Parse la page HTML de Geofabrik pour extraire les fichiers .mbtiles.
  Future<void> _fetchRemoteMaps() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    await _refreshDownloadedFiles();

    try {
      final response = await _dio.get<String>(_baseUrl);
      if (response.data == null) throw Exception('Réponse vide');

      // Regex pour extraire les liens href vers des .mbtiles
      // On utilise deux patterns séparés pour les guillemets doubles et simples
      final hrefRegexDouble = RegExp(r'href="([^"]+\.mbtiles)"', caseSensitive: false);
      final hrefRegexSingle = RegExp("href='([^']+\\.mbtiles)'", caseSensitive: false);
      // On unifie les matches dans une seule liste
      final sizeRegex = RegExp(r'([\d.]+)\s*([MGK])', caseSensitive: false);

      final maps = <_RemoteMap>[];
      final seenIds = <String>{};

      // Matches sur guillemets doubles puis simples
      final allMatches = [
        ...hrefRegexDouble.allMatches(response.data!),
        ...hrefRegexSingle.allMatches(response.data!),
      ];

      for (final match in allMatches) {
        final href = match.group(1)!;
        final filename = href.split('/').last;
        if (seenIds.contains(filename)) continue;
        seenIds.add(filename);

        // Estimation de la taille à partir du contenu HTML autour du lien
        double sizeMb = 0;
        final start = (match.start - 200).clamp(0, response.data!.length);
        final end = (match.end + 200).clamp(0, response.data!.length);
        final context = response.data!.substring(start, end);
        final sizeMatch = sizeRegex.firstMatch(context);
        if (sizeMatch != null) {
          final val = double.tryParse(sizeMatch.group(1)!) ?? 0;
          final unit = sizeMatch.group(2)!.toUpperCase();
          sizeMb = unit == 'G'
              ? val * 1024
              : unit == 'M'
                  ? val
                  : val / 1024;
        }

        final downloadUrl = href.startsWith('http')
            ? href
            : '$_baseUrl$filename';

        maps.add(_RemoteMap(
          id: filename,
          name: filename
              .replaceAll('.mbtiles', '')
              .replaceAll('-', ' ')
              .replaceAll('_', ' ')
              .trim(),
          sizeMb: sizeMb,
          isTerrain: filename.contains('terrain') || filename.contains('dem'),
          downloadUrl: downloadUrl,
        ));
      }

      setState(() {
        _maps = maps;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
        _errorMessage =
            'Impossible de récupérer la liste.\nVérifiez votre connexion.\n\nDétail : $e';
      });
    }
  }

  Future<void> _downloadMap(_RemoteMap map) async {
    final dir = await _getMapsDirectory();
    final savePath = '${dir.path}/${map.id}';

    setState(() => _downloadProgress[map.id] = 0.0);

    try {
      await _dio.download(
        map.downloadUrl,
        savePath,
        onReceiveProgress: (received, total) {
          if (total > 0 && mounted) {
            setState(() => _downloadProgress[map.id] = received / total);
          }
        },
      );
      setState(() {
        _downloadProgress.remove(map.id);
        _downloadedFiles.add(map.id);
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${map.name} téléchargé !'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      // Nettoyage du fichier partiel
      try {
        final partial = File(savePath);
        if (await partial.exists()) await partial.delete();
      } catch (_) {}

      setState(() => _downloadProgress.remove(map.id));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Erreur : $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _deleteMap(_RemoteMap map) async {
    final dir = await _getMapsDirectory();
    final file = File('${dir.path}/${map.id}');
    if (await file.exists()) await file.delete();
    await _refreshDownloadedFiles();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Center(child: CircularProgressIndicator());

    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.cloud_off, size: 56, color: Colors.grey),
              const SizedBox(height: 16),
              Text(_errorMessage!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.grey)),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                icon: const Icon(Icons.refresh),
                label: const Text('Réessayer'),
                onPressed: _fetchRemoteMaps,
              ),
            ],
          ),
        ),
      );
    }

    if (_maps.isEmpty) {
      return const Center(child: Text('Aucun fichier trouvé à cette URL.'));
    }

    return RefreshIndicator(
      onRefresh: _fetchRemoteMaps,
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: _maps.length,
        itemBuilder: (context, index) {
          final map = _maps[index];
          final isDownloaded = _downloadedFiles.contains(map.id);
          final progress = _downloadProgress[map.id];
          final isDownloading = progress != null;

          return Card(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: isDownloaded
                    ? Colors.green.withOpacity(0.15)
                    : map.isTerrain
                        ? Colors.brown.withOpacity(0.15)
                        : Colors.teal.withOpacity(0.15),
                child: isDownloading
                    ? SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          value: progress,
                          strokeWidth: 2.5,
                        ),
                      )
                    : Icon(
                        isDownloaded
                            ? Icons.check
                            : map.isTerrain
                                ? Icons.terrain
                                : Icons.map,
                        color: isDownloaded
                            ? Colors.green
                            : map.isTerrain
                                ? Colors.brown
                                : Colors.teal,
                      ),
              ),
              title: Text(
                map.name,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: isDownloading
                  ? LinearProgressIndicator(value: progress)
                  : Text(
                      isDownloaded
                          ? '✓ Disponible hors-ligne'
                          : map.sizeMb > 0
                              ? '${map.sizeMb.toStringAsFixed(0)} MB'
                              : map.isTerrain
                                  ? 'Terrain DEM'
                                  : 'Carte vectorielle',
                    ),
              trailing: isDownloading
                  ? Text('${(progress * 100).toStringAsFixed(0)}%')
                  : isDownloaded
                      ? IconButton(
                          icon: const Icon(Icons.delete_outline,
                              color: Colors.red),
                          onPressed: () => _deleteMap(map),
                        )
                      : IconButton(
                          icon: const Icon(Icons.download_for_offline,
                              color: Colors.teal),
                          onPressed: () => _downloadMap(map),
                        ),
            ),
          );
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Modèle de données
// ─────────────────────────────────────────────────────────────────────────────

class _RemoteMap {
  final String id;
  final String name;
  final double sizeMb;
  final bool isTerrain;
  final String downloadUrl;

  const _RemoteMap({
    required this.id,
    required this.name,
    required this.sizeMb,
    required this.isTerrain,
    required this.downloadUrl,
  });
}