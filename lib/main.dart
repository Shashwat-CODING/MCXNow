import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const StockApp();
  }
}

/// Minimal SSE client implemented using `package:http` streamed response.
class SseClient {
  SseClient(this.uri, {Map<String, String>? headers})
      : _headers = {
          'Accept': 'text/event-stream',
          'Cache-Control': 'no-cache',
          'Connection': 'keep-alive',
          if (headers != null) ...headers,
        };

  final Uri uri;
  final Map<String, String> _headers;
  final StreamController<SseEvent> _controller =
      StreamController<SseEvent>.broadcast();
  http.Client? _client;
  StreamSubscription<List<int>>? _sub;
  bool _closed = false;

  Stream<SseEvent> get stream => _controller.stream;

  Future<void> connect() async {
    if (_closed) return;
    await close();
    _closed = false;
    _client = http.Client();
    final request = http.Request('GET', uri);
    request.headers.addAll(_headers);
    late http.StreamedResponse resp;
    try {
      resp = await _client!.send(request);
    } catch (e) {
      _controller.addError(e);
      await close();
      return;
    }
    if (resp.statusCode != 200) {
      _controller.addError(
        StateError('SSE connect failed: HTTP ${resp.statusCode}'),
      );
      await close();
      return;
    }

    String eventName = 'message';
    final List<String> dataLines = <String>[];

    void dispatch() {
      if (dataLines.isEmpty) return;
      final data = dataLines.join('\n');
      _controller.add(SseEvent(eventName, data));
      eventName = 'message';
      dataLines.clear();
    }

    _sub = resp.stream.listen(
      (chunk) {
        final text = utf8.decode(chunk);
        for (final rawLine in const LineSplitter().convert(text)) {
          final line = rawLine;
          if (line.isEmpty) {
            dispatch();
            continue;
          }
          if (line.startsWith(':')) {
            // comment/keepalive
            continue;
          }
          final int colon = line.indexOf(':');
          String field;
          String value = '';
          if (colon == -1) {
            field = line;
          } else {
            field = line.substring(0, colon);
            value = line.substring(colon + 1);
            if (value.startsWith(' ')) value = value.substring(1);
          }
          switch (field) {
            case 'event':
              eventName = value;
              break;
            case 'data':
              dataLines.add(value);
              break;
            case 'id':
              // Not used
              break;
            case 'retry':
              // Not used
              break;
            default:
              break;
          }
        }
      },
      onDone: () {
        dispatch();
        _controller.close();
      },
      onError: (e) {
        _controller.addError(e);
      },
      cancelOnError: false,
    );
  }

  Future<void> close() async {
    _closed = true;
    await _sub?.cancel();
    _sub = null;
    _client?.close();
    _client = null;
  }
}

class SseEvent {
  const SseEvent(this.event, this.data);
  final String event;
  final String data;
}

class StockApp extends StatefulWidget {
  const StockApp({super.key});

  @override
  State<StockApp> createState() => _StockAppState();
}

class _StockAppState extends State<StockApp> {
  static const String baseUrl = 'https://shashwatidr-stocks.hf.space';
  static const Duration reconnectBackoffInitial = Duration(seconds: 2);
  static const Duration reconnectBackoffMax = Duration(seconds: 30);
  static const Duration idleTimeout = Duration(seconds: 5);

  final Map<String, Map<String, dynamic>> symbolToStock = {};
  final Map<String, DateTime> recentlyChangedAt = {};
  final Map<String, String> recentChangeType = {};
  final TextEditingController searchController = TextEditingController();

  // Advanced options
  final Set<String> watchlist = <String>{};
  bool showWatchlistOnly = false;
  // Grid layout removed; only list view is supported

  SseClient? _sse;
  StreamSubscription<SseEvent>? _sseSub;
  bool _loading = true;
  String? _error;
  String _connectionStatus = 'Connecting...';
  Duration _currentBackoff = reconnectBackoffInitial;
  Timer? _idleTimer;
  final GlobalKey<NavigatorState> _navKey = GlobalKey<NavigatorState>();
  bool _reconnecting = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final wl = prefs.getStringList('watchlist') ?? <String>[];
    final only = prefs.getBool('showWatchlistOnly') ?? false;
    setState(() {
      watchlist
        ..clear()
        ..addAll(wl);
      showWatchlistOnly = only;
    });
  }

  Future<void> _savePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('watchlist', watchlist.toList()..sort());
    // gridColumns removed
    await prefs.setBool('showWatchlistOnly', showWatchlistOnly);
  }

  void _toggleWatchlist(String symbol) {
    setState(() {
      if (watchlist.contains(symbol)) {
        watchlist.remove(symbol);
      } else {
        watchlist.add(symbol);
      }
    });
    _savePrefs();
  }

  // Grid layout removed

  void _toggleWatchlistFilter() {
    setState(() {
      showWatchlistOnly = !showWatchlistOnly;
    });
    _savePrefs();
  }

  Future<void> _bootstrap() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      await _fetchInitialRates();
      await _connectSse();
      setState(() {
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Failed to initialize: $e';
        _loading = false;
      });
      _scheduleReconnect();
    }
  }

  Future<void> _fetchInitialRates() async {
    final uri = Uri.parse('$baseUrl/rate');
    final res = await http.get(uri).timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) {
      throw Exception('GET /rate failed (${res.statusCode})');
    }
    final decoded = jsonDecode(res.body) as Map<String, dynamic>;
    final List<dynamic> data = (decoded['data'] as List<dynamic>? ?? []);
    final Map<String, Map<String, dynamic>> nextMap = {};
    for (final item in data) {
      if (item is Map<String, dynamic>) {
        final symbol = (item['Symbol'] ?? '').toString().trim();
        if (symbol.isEmpty) continue;
        nextMap[symbol] = item;
      }
    }
    setState(() {
      symbolToStock
        ..clear()
        ..addAll(nextMap);
      _connectionStatus = 'Connected';
    });
  }

  Future<void> _connectSse() async {
    await _disposeSse();
    setState(() {
      _connectionStatus = 'Connecting to live updates...';
    });

    final client = SseClient(Uri.parse('$baseUrl/events'));
    _sse = client;
    try {
      await client.connect();
    } catch (e) {
      setState(() {
        _connectionStatus = 'Disconnected';
        _error = 'Failed to connect SSE: $e';
      });
      _scheduleReconnect();
      return;
    }

    _sseSub = client.stream.listen(
      (evt) {
        _resetIdleTimer();
        switch (evt.event) {
          case 'connected':
            setState(() {
              _connectionStatus = 'Live updates active';
              _currentBackoff = reconnectBackoffInitial;
            });
            break;
          case 'rateUpdate':
            _handleRateUpdate(evt.data);
            break;
          case 'ping':
            // optional keepalive handling
            break;
          case 'error':
            _handleServerError(evt.data);
            break;
          default:
            // ignore
            break;
        }
      },
      onError: (err, st) {
        setState(() {
          _connectionStatus = 'Disconnected';
          _error = 'SSE error: $err';
        });
        _cancelIdleTimer();
        _reconnectSoon('error');
      },
      onDone: () {
        setState(() {
          _connectionStatus = 'Disconnected';
        });
        _cancelIdleTimer();
        _reconnectSoon('done');
      },
      cancelOnError: false,
    );

    // Start idle watchdog once connected
    _resetIdleTimer();
  }

  void _handleRateUpdate(String? data) {
    if (data == null || data.isEmpty) return;
    try {
      final Map<String, dynamic> changed =
          jsonDecode(data) as Map<String, dynamic>;
      bool anyChange = false;

      changed.forEach((symbol, stockData) {
        if (stockData is Map<String, dynamic>) {
          final key = symbol.toString().trim();
          final existing = symbolToStock[key];
          if (existing != null) {
            existing.addAll(stockData);
          } else {
            symbolToStock[key] = Map<String, dynamic>.from(stockData);
          }
          recentlyChangedAt[key] = DateTime.now();
          final ct = (stockData['changeType'] ?? '').toString();
          if (ct.isNotEmpty) {
            recentChangeType[key] = ct;
          }
          anyChange = true;
        }
      });

      if (anyChange) {
        setState(() {});
      }
    } catch (_) {
      // ignore malformed
    }
  }

  void _handleServerError(String? data) {
    try {
      final Map<String, dynamic> payload =
          data == null ? {} : jsonDecode(data) as Map<String, dynamic>;
      final msg = payload['error']?.toString() ?? 'Server error';
      setState(() {
        _error = msg;
      });
    } catch (_) {
      setState(() {
        _error = 'Server error';
      });
    }
  }

  void _scheduleReconnect() {
    Future.delayed(_currentBackoff, () async {
      if (!mounted) return;
      await _connectSse();
    });
    _currentBackoff = Duration(
      seconds: (_currentBackoff.inSeconds * 2).clamp(
        reconnectBackoffInitial.inSeconds,
        reconnectBackoffMax.inSeconds,
      ),
    );
  }

  Future<void> _disposeSse() async {
    await _sseSub?.cancel();
    _sseSub = null;
    await _sse?.close();
    _sse = null;
    _cancelIdleTimer();
  }

  @override
  void dispose() {
    _disposeSse();
    searchController.dispose();
    super.dispose();
  }

  double? _toDouble(dynamic value) {
    if (value == null) return null;
    final s = value.toString().trim().replaceAll(',', '');
    if (s.isEmpty) return null;
    return double.tryParse(s);
  }

  Color _rowColor(String symbol, bool isUp) {
    // Base tint reflects current gain/loss state
    final Color base = (isUp ? Colors.green : Colors.red)
        .withValues(alpha: 0.06);

    final DateTime? changedAt = recentlyChangedAt[symbol];
    if (changedAt == null) return base;

    final Duration elapsed = DateTime.now().difference(changedAt);
    const int flashMs = 1800;
    if (elapsed.inMilliseconds >= flashMs) return base;

    final double t = 1.0 - (elapsed.inMilliseconds / flashMs).clamp(0.0, 1.0);
    final String ct = recentChangeType[symbol] ?? (isUp ? 'increase' : 'decrease');
    final Color flashColor = (ct == 'increase' ? Colors.green : Colors.red)
        .withValues(alpha: 0.35);

    return Color.lerp(base, flashColor, t) ?? base;
  }

  // Format with Indian digit grouping while preserving up to [maxFractionDigits] without rounding
  String _formatIndianNumberString(String raw, {int maxFractionDigits = 5}) {
    String s = raw.toString().trim();
    if (s.isEmpty) return s;
    String sign = '';
    if (s.startsWith('-') || s.startsWith('+')) {
      sign = s[0];
      s = s.substring(1);
    }
    s = s.replaceAll(',', '');
    final parts = s.split('.');
    String intPart = parts[0];
    String fracPart = parts.length > 1 ? parts.sublist(1).join('.') : '';
    if (fracPart.length > maxFractionDigits) {
      fracPart = fracPart.substring(0, maxFractionDigits);
    }
    if (intPart.length <= 3) {
      final withFrac = fracPart.isNotEmpty ? '$intPart.$fracPart' : intPart;
      return '$sign$withFrac';
    }
    final String last3 = intPart.substring(intPart.length - 3);
    String lead = intPart.substring(0, intPart.length - 3);
    final List<String> groups = <String>[];
    while (lead.length > 2) {
      groups.insert(0, lead.substring(lead.length - 2));
      lead = lead.substring(0, lead.length - 2);
    }
    if (lead.isNotEmpty) groups.insert(0, lead);
    final String formattedInt = '${groups.join(',')},$last3';
    final String withFrac = fracPart.isNotEmpty ? '$formattedInt.$fracPart' : formattedInt;
    return '$sign$withFrac';
  }

  // Limit decimals without rounding; no grouping
  String _limitFractionDigits(String raw, int maxFractionDigits) {
    String s = raw.toString().trim();
    if (s.isEmpty) return s;
    String sign = '';
    if (s.startsWith('-') || s.startsWith('+')) {
      sign = s[0];
      s = s.substring(1);
    }
    s = s.replaceAll(',', '');
    final parts = s.split('.');
    if (parts.length == 1) return '$sign${parts[0]}';
    String intPart = parts[0];
    String fracPart = parts.sublist(1).join('.');
    if (fracPart.length > maxFractionDigits) {
      fracPart = fracPart.substring(0, maxFractionDigits);
    }
    return fracPart.isNotEmpty ? '$sign$intPart.$fracPart' : '$sign$intPart';
  }

  // Convert Ser/Exp like 29AUG2025 -> 29 AUG'25 FUT
  String _formatExpiry(String raw) {
    final String t = raw.toString().trim().toUpperCase();
    final RegExp re = RegExp(r'^(\d{1,2})([A-Z]{3})(\d{4})$');
    final m = re.firstMatch(t);
    if (m == null) return raw.toString();
    final String dd = m.group(1)!.padLeft(2, '0');
    final String mon = m.group(2)!;
    final String yy = m.group(3)!.substring(2);
    return "$dd $mon'$yy FUT";
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData lightTheme = ThemeData(
      colorSchemeSeed: Colors.indigo,
      brightness: Brightness.light,
      useMaterial3: true,
    );
    final ThemeData darkTheme = ThemeData(
      colorSchemeSeed: Colors.indigo,
      brightness: Brightness.dark,
      useMaterial3: true,
    );

    final query = searchController.text.trim().toLowerCase();
    final List<MapEntry<String, Map<String, dynamic>>> items = symbolToStock.entries
        .where((e) {
          if (query.isEmpty) return true;
          final data = e.value;
          final symbol = e.key.toLowerCase();
          final exchange = (data['Exchange'] ?? '').toString().toLowerCase();
          return symbol.contains(query) || exchange.contains(query);
        })
        .toList();

    items.sort((a, b) => a.key.compareTo(b.key));

    return MaterialApp(
      title: 'MCXNow',
      theme: lightTheme,
      darkTheme: darkTheme,
      themeMode: ThemeMode.system,
      navigatorKey: _navKey,
      builder: (context, child) => child!,
      home: Scaffold(
        extendBodyBehindAppBar: false,
        appBar: AppBar(
          toolbarHeight: 36,
          backgroundColor: Colors.transparent,
          elevation: 0,
          flexibleSpace: ClipRect(
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
              child: Container(
                color: (Theme.of(context).brightness == Brightness.dark
                        ? Colors.black
                        : Colors.white)
                    .withValues(alpha: 0.18),
              ),
            ),
          ),
          title: const Text('MCXNow'),
          actions: [
            // Search button opens an overlay search bar
            IconButton(
              tooltip: 'Search',
              onPressed: () => _openSearchOverlay(context),
              icon: const Icon(Icons.search),
            ),
            // Watchlist-only toggle
            IconButton(
              tooltip: showWatchlistOnly ? 'Showing Watchlist' : 'Show Watchlist Only',
              onPressed: _toggleWatchlistFilter,
              icon: Icon(
                showWatchlistOnly ? Icons.star : Icons.star_border,
              ),
            ),
            _connectionBadge(),
            IconButton(
              tooltip: 'Refresh now',
              onPressed: () async {
                setState(() {
                  _loading = true;
                  _error = null;
                });
                try {
                  await _fetchInitialRates();
                } catch (e) {
                  setState(() {
                    _error = 'Refresh failed: $e';
                  });
                } finally {
                  setState(() {
                    _loading = false;
                  });
                }
              },
              icon: const Icon(Icons.refresh),
            ),
            // Layout picker removed
          ],
          // No inline search bar; replaced with search button
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _buildBody(items),
      ),
    );
  }

  Widget _buildBody(
    List<MapEntry<String, Map<String, dynamic>>> items,
  ) {
    if (_error != null) {
      return Center(
        child: Text(
          _error!,
          style: const TextStyle(color: Colors.red),
          textAlign: TextAlign.center,
        ),
      );
    }

    if (items.isEmpty) {
      return const Center(child: Text('No data'));
    }

    // Apply watchlist filter if enabled
    final List<MapEntry<String, Map<String, dynamic>>> visibleItems = showWatchlistOnly
        ? items.where((e) => watchlist.contains(e.key)).toList()
        : items;

    // Grid view removed; only list view remains

    // Default list view
    return RefreshIndicator(
      onRefresh: _fetchInitialRates,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        itemCount: visibleItems.length,
        itemBuilder: (context, index) {
          final symbol = visibleItems[index].key;
          final data = visibleItems[index].value;
          return _buildListCard(symbol, data);
        },
      ),
    );
  }

  Widget _buildGridCard(String symbol, Map<String, dynamic> data) {
    final String ltpRaw = (data['Last Traded Price'] ?? '').toString();
    final String openRaw = (data['Open'] ?? '').toString();
    final String ltpDisp = _formatIndianNumberString(ltpRaw, maxFractionDigits: 5);
    final String openDisp = _formatIndianNumberString(openRaw, maxFractionDigits: 5);
    final String netChangeRaw = (data['Net Change In Rs'] ?? '').toString();
    final String pctChangeRaw = (data['% Net Change In Rs'] ?? '').toString();
    final double? netChange = _toDouble(netChangeRaw);
    final bool isUp = (netChange ?? 0) >= 0;
    final Color color = isUp ? Colors.green : Colors.red;
    final String arrow = isUp ? '▲' : '▼';
    final String netChangeDisp = netChange == null
        ? netChangeRaw
        : _formatIndianNumberString(netChange.toString(), maxFractionDigits: 5);
    final String pctDisp = _limitFractionDigits(pctChangeRaw, 5);
    final String changeText = pctDisp.isNotEmpty
        ? '$arrow $netChangeDisp ($pctDisp%)'
        : '$arrow $netChangeDisp';

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _showDetails(symbol, data),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          decoration: BoxDecoration(
            color: _rowColor(symbol, isUp),
            borderRadius: BorderRadius.circular(14),
          ),
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Text(
                    symbol,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontWeight: FontWeight.w800,
                      fontSize: 16,
                    ),
                  ),
                  ),
                  IconButton(
                    icon: Icon(
                      watchlist.contains(symbol) ? Icons.star : Icons.star_border,
                      size: 20,
                    ),
                    onPressed: () => _toggleWatchlist(symbol),
                    tooltip: watchlist.contains(symbol)
                        ? 'Remove from watchlist'
                        : 'Add to watchlist',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  )
                ],
              ),
              const Spacer(),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Text(
                      ltpDisp,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 24,
                        color: color,
                      ),
                    ),
                  ),
                    const SizedBox(width: 6),
                  Flexible(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: _changePill(
                        changeText,
                        color,
                      ),
                      ),
                    ),
                  ],
              ),
              const SizedBox(height: 6),
              Text(
                'Open: $openDisp',
                style: const TextStyle(fontSize: 12, color: Colors.white70),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildListCard(String symbol, Map<String, dynamic> data) {
    final String symbolStr = symbol;
    final String exch = (data['Exchange'] ?? '').toString();
    final String expiryRaw = (data['Ser/Exp'] ?? '').toString();
    final String expiry = _formatExpiry(expiryRaw);

    final String ltpRaw = (data['Last Traded Price'] ?? '').toString();
    final String openRaw = (data['Open'] ?? '').toString();
    final String ltpDisp = _formatIndianNumberString(ltpRaw, maxFractionDigits: 5);
    final String openDisp = _formatIndianNumberString(openRaw, maxFractionDigits: 5);
    final String netChangeRaw = (data['Net Change In Rs'] ?? '').toString();
    final String pctChangeRaw = (data['% Net Change In Rs'] ?? '').toString();
    final double? netChange = _toDouble(netChangeRaw);
    final bool isUp = (netChange ?? 0) >= 0;
    final Color color = isUp ? Colors.green : Colors.red;
    final String arrow = isUp ? '▲' : '▼';
    final String netChangeDisp = netChange == null
        ? netChangeRaw
        : _formatIndianNumberString(netChange.toString(), maxFractionDigits: 5);
    final String pctDisp = _limitFractionDigits(pctChangeRaw, 5);
    final String changeText = pctDisp.isNotEmpty
        ? '$arrow $netChangeDisp ($pctDisp%)'
        : '$arrow $netChangeDisp';

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _showDetails(symbol, data),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          margin: const EdgeInsets.only(bottom: 10),
          decoration: BoxDecoration(
            color: _rowColor(symbol, isUp),
            borderRadius: BorderRadius.circular(14),
          ),
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            symbolStr,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 18,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          exch,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 12,
                            color: Colors.white70,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      expiry,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.white70,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Open: $openDisp',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.white70,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: Icon(
                  watchlist.contains(symbol) ? Icons.star : Icons.star_border,
                ),
                onPressed: () => _toggleWatchlist(symbol),
                tooltip: watchlist.contains(symbol)
                    ? 'Remove from watchlist'
                    : 'Add to watchlist',
              ),
              const SizedBox(width: 4),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    ltpDisp,
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 22,
                      color: color,
                    ),
                  ),
                  const SizedBox(height: 6),
                  _changePill(changeText, color),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _chip(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black12,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: const TextStyle(fontSize: 12),
      ),
    );
  }

  Widget _changePill(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        text,
                    style: TextStyle(
                      fontSize: 12,
          fontWeight: FontWeight.w700,
                      color: color,
                    ),
      ),
    );
  }

  Widget _smallKv(String k, String v) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black12,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$k: ',
            style: const TextStyle(fontSize: 12, color: Colors.black54),
          ),
          Text(
            v,
            style: const TextStyle(fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _connectionBadge() {
    Color c;
    switch (_connectionStatus) {
      case 'Live updates active':
      case 'Connected':
        c = Colors.green;
        break;
      case 'Connecting to live updates...':
      case 'Connecting...':
        c = Colors.orange;
        break;
      default:
        c = Colors.red;
    }
    return Tooltip(
      message: _connectionStatus,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8.0),
        child: Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: c,
            shape: BoxShape.circle,
          ),
              ),
            ),
          );
  }

  void _resetIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = Timer(idleTimeout, () {
      if (!mounted) return;
      _reconnectDueToIdle();
    });
  }

  void _cancelIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = null;
  }

  Future<void> _reconnectDueToIdle() async {
    _reconnectSoon('idle');
  }

  Future<void> _reconnectSoon(String reason) async {
    if (_reconnecting) return;
    _reconnecting = true;
    setState(() {
      _connectionStatus = 'Reconnecting ($reason)...';
    });
    await _disposeSse();
    // Tiny delay to allow sockets to fully close
    await Future.delayed(const Duration(milliseconds: 400));
    if (!mounted) return;
    _reconnecting = false;
    await _connectSse();
  }

  Future<void> _openSearchOverlay(BuildContext pageContext) async {
    final BuildContext ctx = _navKey.currentContext ?? pageContext;
    final String? result = await showSearch(
      context: ctx,
      delegate: StockSearchDelegate(
        initialQuery: searchController.text,
      ),
      useRootNavigator: true,
    );
    if (result != null) {
      setState(() {
        searchController.text = result;
      });
    }
  }

  Future<void> _showDetails(String symbol, Map<String, dynamic> data) async {
    final BuildContext ctx = _navKey.currentContext ?? context;
    final ColorScheme scheme = Theme.of(ctx).colorScheme;
    final String ltpStr = (data['Last Traded Price'] ?? '').toString();
    final double? ltp = _toDouble(ltpStr);
    final double? pct = _toDouble((data['% Net Change In Rs'] ?? '').toString());
    final double? changeAmt = _toDouble((data['Net Change In Rs'] ?? '').toString());
    final String changeType = (data['changeType'] ?? '').toString();
    final bool isUp = changeType == 'increase'
        ? true
        : changeType == 'decrease'
            ? false
            : (pct ?? 0) >= 0;
    final Color changeColor = isUp ? Colors.green : Colors.red;
    final String arrow = isUp ? '▲' : '▼';

    final entries = data.entries.toList()
      ..sort((a, b) => a.key.toString().compareTo(b.key.toString()));

    await showModalBottomSheet(
      context: ctx,
      useRootNavigator: true,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      symbol,
                      style: const TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 20,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      watchlist.contains(symbol) ? Icons.star : Icons.star_border,
                    ),
                    tooltip: watchlist.contains(symbol)
                        ? 'Remove from watchlist'
                        : 'Add to watchlist',
                    onPressed: () {
                      _toggleWatchlist(symbol);
                      Navigator.of(ctx).pop();
                      _showDetails(symbol, data);
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(ctx).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Text(
                    ltp == null ? ltpStr : _formatPrice(ltp),
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 26,
                      color: changeColor,
                    ),
                  ),
                  const SizedBox(width: 10),
                  _changePill(
                    _formatChange(changeAmt, pct, arrow),
                    changeColor,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Divider(color: scheme.outlineVariant),
              const SizedBox(height: 8),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: entries.length,
                  separatorBuilder: (_, __) => Divider(
                    color: scheme.outlineVariant,
                    height: 1,
                  ),
                  itemBuilder: (context, index) {
                    final e = entries[index];
                    final key = e.key.toString().trim();
                    final value = e.value;
                    final valueStr = value?.toString().trim() ?? '';
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 160,
                            child: Text(
                              key,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              valueStr,
                              textAlign: TextAlign.right,
                            ),
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
    );
  }

  String _formatPrice(double v) {
    // Deprecated: preserve all digits; keep wrapper for detail sheet but avoid rounding
    return _formatIndianNumberString(v.toString(), maxFractionDigits: 5);
  }

  String _formatChange(double? changeAmount, double? pct, String arrow) {
    final String amt = changeAmount == null
        ? ''
        : _formatIndianNumberString(changeAmount.toString(), maxFractionDigits: 5);
    final String pctStr = pct == null ? '' : _limitFractionDigits(pct.toString(), 5);
    if (amt.isNotEmpty && pctStr.isNotEmpty) {
      return '$arrow $amt ($pctStr%)';
    } else if (amt.isNotEmpty) {
      return '$arrow $amt';
    } else if (pctStr.isNotEmpty) {
      return '$arrow $pctStr%';
    }
    return arrow;
  }

  Widget _kv(String k, String v) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$k: ',
          style: const TextStyle(
            fontSize: 12,
            color: Colors.black54,
          ),
        ),
        Text(
          v,
          style: const TextStyle(
            fontSize: 12,
          ),
        ),
      ],
    );
  }
}

class StockSearchDelegate extends SearchDelegate<String> {
  StockSearchDelegate({
    required this.initialQuery,
  }) {
    query = initialQuery;
  }

  final String initialQuery;

  @override
  String get searchFieldLabel => 'Search symbol or exchange';

  @override
  List<Widget>? buildActions(BuildContext context) {
    return [
      if (query.isNotEmpty)
        IconButton(
          tooltip: 'Clear',
          icon: const Icon(Icons.clear),
          onPressed: () {
            query = '';
            showSuggestions(context);
          },
        )
    ];
  }

  @override
  Widget? buildLeading(BuildContext context) {
    return IconButton(
      tooltip: 'Back',
      icon: const Icon(Icons.arrow_back),
      onPressed: () => close(context, query),
    );
  }

  @override
  Widget buildResults(BuildContext context) {
    close(context, query);
    return const SizedBox.shrink();
  }

  @override
  Widget buildSuggestions(BuildContext context) {
    // No live suggestions; pressing enter closes with current query
    return const SizedBox.shrink();
  }
}
