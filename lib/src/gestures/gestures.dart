import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_map/src/core/point.dart';
import 'package:flutter_map/src/core/util.dart' as util;
import 'package:flutter_map/src/map/map.dart';
import 'package:latlong/latlong.dart';
import 'package:flutter_map/flutter_map.dart';

abstract class MapGestureMixin extends State<FlutterMap>
    with TickerProviderStateMixin {
  static const double _kMinFlingVelocity = 800.0;

  LatLng _mapCenterStart;
  double _mapZoomStart;
  Point _focalPointStart;

  LatLng _lastTapPoint;

  AnimationController _controller;
  Animation<Offset> _flingAnimation;

  Offset _animationOffset = Offset.zero;
  AnimationController _doubleTapController;

  Animation _doubleTapAnimation;

  FlutterMap get widget;
  MapState get mapState;
  MapState get map => mapState;
  MapOptions get options;

  @override
  void initState() {
    super.initState();
    _controller = new AnimationController(vsync: this)
      ..addListener(_handleFlingAnimation);
    _doubleTapController = new AnimationController(
        vsync: this, duration: Duration(milliseconds: 200))
      ..addListener(_handleDoubleTapZoomAnimation);
  }

  void handleScaleStart(ScaleStartDetails details) {
    setState(() {
      _mapZoomStart = map.zoom;
      _mapCenterStart = map.center;

      // Get the widget's offset
      var renderObject = context.findRenderObject() as RenderBox;
      var boxOffset = renderObject.localToGlobal(Offset.zero);

      // determine the focal point within the widget
      var localFocalPoint = _offsetToPoint(details.focalPoint - boxOffset);
      _focalPointStart = localFocalPoint;

      _controller.stop();
    });
  }

  void handleScaleUpdate(ScaleUpdateDetails details) {
    setState(() {
      var dScale = details.scale;
      for (var i = 0; i < 2; i++) {
        dScale = math.sqrt(dScale);
      }
      var renderObject = context.findRenderObject() as RenderBox;
      var boxOffset = renderObject.localToGlobal(Offset.zero);

      // Draw the focal point
      var localFocalPoint = _offsetToPoint(details.focalPoint - boxOffset);

      // get the focal point in global coordinates
      var dFocalPoint = localFocalPoint - _focalPointStart;

      var focalCenterDistance = localFocalPoint - (map.size / 2);
      var newCenter = map.project(_mapCenterStart) +
          focalCenterDistance.multiplyBy(1 - 1 / dScale) -
          dFocalPoint;

      var offsetPt = newCenter - map.project(_mapCenterStart);
      _animationOffset = _pointToOffset(offsetPt);

      var newZoom = _mapZoomStart * dScale;
      map.move(map.unproject(newCenter), newZoom, hasGesture: true);
    });
  }

  void handleScaleEnd(ScaleEndDetails details) {
    final double magnitude = details.velocity.pixelsPerSecond.distance;
    if (magnitude < _kMinFlingVelocity) return;
    final Offset direction = details.velocity.pixelsPerSecond / magnitude;
    final double distance = (Offset.zero & context.size).shortestSide;
    _flingAnimation = new Tween<Offset>(
            begin: _animationOffset,
            end: _animationOffset - direction * distance)
        .animate(_controller);
    _controller
      ..value = 0.0
      ..fling(velocity: magnitude / 1000.0);
  }

  void handleTapUp(TapUpDetails details) {

    // Get the widget's offset
    var renderObject = context.findRenderObject() as RenderBox;
    var boxOffset = renderObject.localToGlobal(Offset.zero);
    var width = renderObject.size.width;
    var height = renderObject.size.height;

    // convert the point to global coordinates
    _lastTapPoint =
        map.offsetToLatLng(details.globalPosition, boxOffset, width, height);
  }

  void handleTap() {
    if (_lastTapPoint == null) {
      return;
    }

    var test = _elementHitTest(_lastTapPoint);

    // emit the event
    if (test != null) {
      var layer = test.keys.first;
      if (layer.onTap != null) {
        layer.onTap(test[layer], _lastTapPoint);
      }
    } else if (options.onTap != null) options.onTap(_lastTapPoint);
  }

  void handleLongPress() {
    if (_lastTapPoint == null) {
      return;
    }

    var test = _elementHitTest(_lastTapPoint);

    // emit the event
    if (test != null) {
      var layer = test.keys.first;
      if (layer.onTap != null) {
        layer.onLongPress(test[layer], _lastTapPoint);
      }
    } else if (options.onTap != null) options.onLongPress(_lastTapPoint);
  }

  void handleDoubleTap() {
    ///Currently zooms in the center of the screen
    ///TODO: change the newCenter to be where the user tapped, see https://github.com/flutter/flutter/issues/10048

    _mapZoomStart = map.zoom;
    _mapCenterStart = map.center;

    double dScale = 2.0;
    for (var i = 0; i < 2; i++) {
      dScale = math.sqrt(dScale);
    }

    double newZoom = _mapZoomStart * dScale;

    _doubleTapAnimation = new Tween<double>(
      begin: _mapZoomStart,
      end: newZoom,
    )
        .chain(new CurveTween(curve: Curves.fastOutSlowIn))
        .animate(_doubleTapController);
    _doubleTapController
      ..value = 0.0
      ..forward();
  }

  void _handleDoubleTapZoomAnimation() {
    var newCenter = map.project(_mapCenterStart);
    setState(() {
      map.move(map.unproject(newCenter), _doubleTapAnimation.value, hasGesture: true);
    });
  }

  void _handleFlingAnimation() {
    setState(() {
      _animationOffset = _flingAnimation.value;
      var newCenterPoint = map.project(_mapCenterStart) +
          new Point(_animationOffset.dx, _animationOffset.dy);
      var newCenter = map.unproject(newCenterPoint);
      map.move(newCenter, map.zoom, hasGesture: true);
    });
  }

  Point _offsetToPoint(Offset offset) {
    return new Point(offset.dx, offset.dy);
  }

  Offset _pointToOffset(Point point) {
    return new Offset(point.x.toDouble(), point.y.toDouble());
  }

  /// Returns a map of the layer and the element touched.
  Map _elementHitTest(LatLng point) {
    var offset = map.latlngToOffset(point);
    var tap = Rect.fromCircle(center: offset, radius: 10.0);
    for (var layer in widget.layers.reversed) {
      if (layer is PolygonLayerOptions) {
        var polygon = _polygonHitTest(tap, layer);
        if (polygon != null) return {layer: polygon};
      } else if (layer is PolylineLayerOptions) {
        var polyline = _polylineHitTest(tap, layer);
        if (polyline != null) return {layer: polyline};
      } else if (layer is CircleLayerOptions) {
        var circle = _circleHitTest(tap, layer);
        if (circle != null) return {layer: circle};
      }
    }
    return null;
  }

  /// Returns the first and top-most [Polygon] that overlaps with
  /// tapped [location].
  ///
  /// Returns null if no polygon was touched.
  Polygon _polygonHitTest(Rect tap, PolygonLayerOptions layer) {
    for (var polygon in layer.polygons.reversed) {
      if (tap.overlaps(polygon.bounds)) {
        for (var i = 0; i < polygon.offsets.length - 1; i++) {
          if (util.intersects(polygon.offsets[i], polygon.offsets[i + 1], tap)) {
            return polygon;
          }
        }
      }
    }
    return null;
  }

  /// Returns the first and top-most [Polyline] that overlaps with
  /// tapped [location].
  ///
  /// Returns null if no polyline was touched.
  Polyline _polylineHitTest(Rect tap, PolylineLayerOptions layer) {
    for (var polyline in layer.polylines.reversed) {
      if (tap.overlaps(polyline.bounds)) {
        for (var i = 0; i < polyline.offsets.length - 1; i++) {
          if (util.intersects(polyline.offsets[i], polyline.offsets[i + 1], tap)) {
            return polyline;
          }
        }
      }
    }
    return null;
  }

  /// Returns the first and top-most [Circle] that overlaps with
  /// tapped [location].
  ///
  /// Returns null if no Circle was touched.
  CircleMarker _circleHitTest(Rect tap, CircleLayerOptions layer) {
    for (var circle in layer.circles.reversed) {
      if (tap.overlaps(Rect.fromCircle(center: circle.offset, radius: circle.radius))) {
        return circle;
      }
    }
    return null;
  }

  @override
  void dispose() {
    _controller.dispose();
    _doubleTapController.dispose();
    super.dispose();
  }
}
