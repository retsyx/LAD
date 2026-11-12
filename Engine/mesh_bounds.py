"""Conservative geometric acceptance for reconstructed, finite native B-reps.

This module does not establish topology/material equivalence.  Its reference is
exactly the supplied triangle surface set.  It never treats a requested OCCT
meshing deflection, optimizer convergence, or a sampled maximum as a bound.

Supported surfaces: planes, cylinders, cones, spheres, tori, and nonperiodic
positive-weight B-spline/Bezier surfaces. Supported UV trims include lines,
circles, ellipses and nonperiodic positive-weight B-spline/Bezier curves.
Unsupported representations fail closed. Each UV
rectangle is either proved outside the trim, or retained in the verification
cover.  A winding computation is used only outside conservative enclosures of
all trim segments.  Boundaries are therefore covered even when their membership
is numerically uncertain.

Arithmetic uses outward-rounded binary64 elementary operations and a Taylor
remainder enclosure for trigonometry (not libm sin/cos accuracy assumptions).
The OCCT geometric coefficients and pcurves returned by the kernel are the
engineering representation being verified.  Native representation validity and
edge/pcurve consistency must be checked separately by the caller.  The report
records this scope, including closure of UV endpoint roundoff-sized gaps.
"""
from __future__ import annotations

from dataclasses import dataclass
from functools import lru_cache
import heapq
import math
import sys
from typing import Any

import numpy as np
from scipy.spatial import cKDTree

from mesh_reference import triangle_distances


_EPS = sys.float_info.epsilon
_INF = float("inf")


def _down(x):
    return math.nextafter(float(x), -_INF)


def _up(x):
    return math.nextafter(float(x), _INF)


class _I:
    __slots__ = ("lo", "hi")

    def __init__(self, lo, hi=None):
        self.lo = float(lo)
        self.hi = float(lo if hi is None else hi)
        if math.isnan(self.lo) or math.isnan(self.hi) or self.lo > self.hi:
            raise ArithmeticError("Invalid or overflowed numerical enclosure")

    def __add__(self, other):
        b = _ival(other)
        return _I(_down(self.lo + b.lo), _up(self.hi + b.hi))

    __radd__ = __add__

    def __neg__(self):
        return _I(-self.hi, -self.lo)

    def __sub__(self, other):
        return self + -_ival(other)

    def __rsub__(self, other):
        return _ival(other) + -self

    def __mul__(self, other):
        b = _ival(other)
        if (self.lo == self.hi == 0) or (b.lo == b.hi == 0):
            return _I(0)
        values = (self.lo * b.lo, self.lo * b.hi,
                  self.hi * b.lo, self.hi * b.hi)
        return _I(_down(min(values)), _up(max(values)))

    __rmul__ = __mul__

    def __truediv__(self, other):
        b = _ival(other)
        if b.lo <= 0 <= b.hi:
            raise ArithmeticError("Unbounded interval division")
        return self * _I(_down(1 / b.hi), _up(1 / b.lo))

    def mid(self):
        return self.lo * 0.5 + self.hi * 0.5


def _ival(x):
    return x if isinstance(x, _I) else _I(x)


def _norm_upper(coords):
    total = _I(0)
    for c in coords:
        a = _ival(c)
        m = max(abs(a.lo), abs(a.hi))
        total = total + _I(m) * m
    return _up(math.sqrt(max(0, total.hi)))


def _difference_upper(a, b):
    return _norm_upper([x - y for x, y in zip(a, b)])


# These decimal literals bracket mathematical pi, rather than a rounded libm pi.
_PI = _I(3.141592653589793, 3.1415926535897936)


@lru_cache(maxsize=65536)
def _sincos(t):
    """Enclose sin/cos at the exact real value represented by float t."""
    if not math.isfinite(t) or abs(t) > 1e8:
        raise ArithmeticError("Trigonometric parameter exceeds supported range")
    q = round(t / (2 * math.pi))
    x = _I(t) - _PI * (2 * q)
    if max(abs(x.lo), abs(x.hi)) > 3.2:
        raise ArithmeticError("Trigonometric range reduction is inconclusive")
    z = x * x
    # Horner evaluation of degree 39/40 Taylor polynomials.  On |x|<=3.2
    # the omitted term is below 2e-28; 1e-25 also encloses all later terms.
    def coefficient(n, sign):
        exact_denominator = math.factorial(n)
        rounded = sign / exact_denominator
        return _I(_down(rounded), _up(rounded))
    sp = coefficient(39, -1)
    cp = coefficient(40, 1)
    for k in range(18, -1, -1):
        sp = coefficient(2 * k + 1, (-1) ** k) + z * sp
    for k in range(19, -1, -1):
        cp = coefficient(2 * k, (-1) ** k) + z * cp
    s = x * sp
    return (_I(max(-1, _down(s.lo - 1e-25)), min(1, _up(s.hi + 1e-25))),
            _I(max(-1, _down(cp.lo - 1e-25)), min(1, _up(cp.hi + 1e-25))))


def _trig_range(a, b):
    mid = a * 0.5 + b * 0.5
    radius = _up(max(abs(mid - a), abs(b - mid)))
    s, c = _sincos(mid)
    # Both functions are 1-Lipschitz.  This is deliberately broader than
    # extrema-aware bounds, but it encloses every point of the interval.
    return (_I(max(-1, _down(s.lo - radius)), min(1, _up(s.hi + radius))),
            _I(max(-1, _down(c.lo - radius)), min(1, _up(c.hi + radius))))


def _vec(values):
    return tuple(_I(v) for v in values)


def _affine(center, *terms):
    return tuple(center[i] + sum((v[i] * k for v, k in terms), _I(0))
                 for i in range(len(center)))


def _orient(a, b, p):
    """Exact orientation of represented floats, with a fast interval filter."""
    det = (_I(b[0]) - a[0]) * (_I(p[1]) - a[1]) - (
        _I(b[1]) - a[1]) * (_I(p[0]) - a[0])
    if det.lo > 0:
        return 1
    if det.hi < 0:
        return -1
    # Rare degeneracies only; Fraction is exact for finite binary64 inputs.
    from fractions import Fraction as F
    value = (F(b[0]) - F(a[0])) * (F(p[1]) - F(a[1])) - (
        F(b[1]) - F(a[1])) * (F(p[0]) - F(a[0]))
    return (value > 0) - (value < 0)


def _winding(p, loops):
    winding = 0
    for loop in loops:
        a, b = loop[:-1], loop[1:]
        rising = np.flatnonzero((a[:, 1] <= p[1]) & (p[1] < b[:, 1]))
        falling = np.flatnonzero((b[:, 1] <= p[1]) & (p[1] < a[:, 1]))
        for index in rising:
            if _orient(a[index], b[index], p) > 0:
                winding += 1
        for index in falling:
            if _orient(a[index], b[index], p) < 0:
                winding -= 1
    return winding


class _Unsupported(ValueError):
    pass


class _Face:
    def __init__(self, face, delta):
        from OCP.BRep import BRep_Tool
        from OCP.BRepTools import BRepTools, BRepTools_WireExplorer
        from OCP.BRepAdaptor import BRepAdaptor_Curve2d
        from OCP.GeomAdaptor import GeomAdaptor_Surface
        from OCP.GeomAbs import (GeomAbs_Plane, GeomAbs_Cylinder, GeomAbs_Cone,
                                 GeomAbs_Sphere, GeomAbs_Torus, GeomAbs_BSplineSurface,
                                 GeomAbs_BezierSurface)
        from OCP.TopAbs import TopAbs_REVERSED
        from OCP.TopLoc import TopLoc_Location

        location = TopLoc_Location()
        raw = BRep_Tool.Surface_s(face.wrapped, location)
        adaptor = GeomAdaptor_Surface(raw)
        kind = adaptor.GetType()
        kinds = {GeomAbs_Plane: ("plane", adaptor.Plane),
                 GeomAbs_Cylinder: ("cylinder", adaptor.Cylinder),
                 GeomAbs_Cone: ("cone", adaptor.Cone),
                 GeomAbs_Sphere: ("sphere", adaptor.Sphere),
                 GeomAbs_Torus: ("torus", adaptor.Torus)}
        is_spline = kind in (GeomAbs_BSplineSurface, GeomAbs_BezierSurface)
        if kind not in kinds and not is_spline:
            raise _Unsupported(f"Surface {kind.name} has no implemented conservative enclosure")
        transform = location.Transformation()
        matrix = [[transform.Value(i, j) for j in range(1, 5)] for i in range(1, 4)]
        def transformed(coords, is_point=False):
            return tuple(sum((_I(matrix[i][j]) * coords[j] for j in range(3)),
                             _I(matrix[i][3] if is_point else 0)) for i in range(3))
        self.spline = None
        if is_spline:
            from mesh_splines import SplineSurface
            self.kind = "bspline"
            geometry = None
            native = adaptor.BSpline() if kind == GeomAbs_BSplineSurface else adaptor.Bezier()
            self.spline = SplineSurface(native, transformed, kind == GeomAbs_BezierSurface)
            self.c = transformed((0,0,0),True)
            self.x,self.y,self.z = [transformed(values) for values in ((1,0,0),(0,1,0),(0,0,1))]
        else:
            self.kind, factory = kinds[kind]
            geometry = factory()
            axes = geometry.Position()
            self.c = transformed(axes.Location().Coord(), True)
            self.x = transformed(axes.XDirection().Coord())
            self.y = transformed(axes.YDirection().Coord())
            self.z = transformed(axes.Direction().Coord())
        self.cn = np.array([x.mid() for x in self.c])
        self.frame = np.array([[x.mid() for x in v] for v in (self.x, self.y, self.z)])
        try:
            self.inverse_frame = np.linalg.inv(self.frame.T)
        except np.linalg.LinAlgError as error:
            raise _Unsupported("Singular analytic surface coordinate frame") from error
        self.nx, self.ny, self.nz = map(_norm_upper, (self.x, self.y, self.z))
        self.r = self.major = 0.0
        self.sa = _I(0)
        self.ca = _I(1)
        if self.kind in ("cylinder", "sphere"):
            self.r = geometry.Radius()
        elif self.kind == "cone":
            self.r = geometry.RefRadius()
            self.sa, self.ca = _sincos(geometry.SemiAngle())
        elif self.kind == "torus":
            self.r, self.major = geometry.MinorRadius(), geometry.MajorRadius()
        self.bounds = tuple(map(float, BRepTools.UVBounds_s(face.wrapped)))
        if not all(math.isfinite(v) and abs(v) < 1e12 for v in self.bounds):
            raise _Unsupported("Infinite or numerically unbounded face parameter domain")
        u0, u1, v0, v1 = self.bounds
        if not (u1 > u0 and v1 > v0):
            raise _Unsupported("Empty or singular face parameter rectangle")
        if self.kind in ("sphere", "torus", "cylinder", "cone") and max(abs(u0), abs(u1)) > 1e8:
            raise _Unsupported("Periodic face parameter exceeds arithmetic enclosure range")
        self.lu, self.lv = self._first_derivative_bounds()
        self.delta = delta
        self.loops = []
        boxes = []
        self.capsules = []
        self.max_trim_closure = 0.0
        self.max_trim_endpoint_enclosure = 0.0
        for wire in face.Wires():
            explorer = BRepTools_WireExplorer(wire.wrapped, face.wrapped)
            points = []
            while explorer.More():
                edge = explorer.Current()
                curve = BRepAdaptor_Curve2d(edge, face.wrapped)
                nodes, segment_boxes, capsules = self._curve_segments(curve)
                if edge.Orientation() == TopAbs_REVERSED:
                    nodes.reverse()
                    segment_boxes.reverse()
                    capsules.reverse()
                if points:
                    self._join(points[-1], nodes[0], boxes)
                points.extend(nodes)
                boxes.extend(segment_boxes)
                self.capsules.extend(capsules)
                explorer.Next()
            if len(points) < 2:
                raise _Unsupported("A trim wire has no supported curve evidence")
            self._join(points[-1], points[0], boxes)
            points.append(points[0])
            self.loops.append(np.array(points, dtype=float))
        if not boxes:
            raise _Unsupported("Face has no finite trim boundary")
        self.boxes = np.array(boxes, dtype=float)
        # UVBounds is a convenient starting estimate, not a certificate.
        # A bounded closed trim can retain no point beyond the enclosure of
        # its boundary.  Cover all analytical pcurve segment boxes.
        self.bounds = (float(self.boxes[:, 0].min()),
                       float(self.boxes[:, 2].max()),
                       float(self.boxes[:, 1].min()),
                       float(self.boxes[:, 3].max()))
        self.lu, self.lv = self._first_derivative_bounds()
        self.trim_padding = ((_I(self.max_trim_closure) + 2 * self.max_trim_endpoint_enclosure) *
                             (_I(self.lu) + self.lv)).hi
        self.boundary_centers = (self.boxes[:, :2] + self.boxes[:, 2:]) * 0.5
        # Scale UV axes to approximate physical units.  Selection only; these
        # approximate metrics never enter an acceptance bound.
        self.metric = np.array([max(self.lu, 1e-30), max(self.lv, 1e-30)])
        self.boundary_tree = cKDTree(self.boundary_centers * self.metric)
        self._eval_cache = {}
        self.seed = self._find_seed()

    def _join(self, a, b, boxes):
        scale = max(1.0, *(abs(x) for x in (*a, *b)))
        gap = _norm_upper((_I(a[0]) - b[0], _I(a[1]) - b[1]))
        if gap > 512 * _EPS * scale:
            raise _Unsupported("UV trim endpoints do not close to arithmetic precision")
        self.max_trim_closure = max(self.max_trim_closure, gap)
        radius = self.max_trim_endpoint_enclosure
        boxes.append([(_I(min(a[0], b[0])) - radius).lo,
                      (_I(min(a[1], b[1])) - radius).lo,
                      (_I(max(a[0], b[0])) + radius).hi,
                      (_I(max(a[1], b[1])) + radius).hi])
        self.capsules.append((a, b, radius))

    def _curve_segments(self, curve):
        from OCP.GeomAbs import (GeomAbs_Line, GeomAbs_Circle, GeomAbs_Ellipse,
                                 GeomAbs_BSplineCurve, GeomAbs_BezierCurve)
        first, last = curve.FirstParameter(), curve.LastParameter()
        if not (math.isfinite(first) and math.isfinite(last) and last > first):
            raise _Unsupported("Unbounded or degenerate trim curve parameter interval")
        kind = curve.GetType()
        if kind in (GeomAbs_BSplineCurve,GeomAbs_BezierCurve):
            from mesh_splines import SplineCurve2D
            native = curve.BSpline() if kind == GeomAbs_BSplineCurve else curve.Bezier()
            spline = SplineCurve2D(native,kind==GeomAbs_BezierCurve)
            target = self.delta*.015/max(self.lu+self.lv,1e-30)
            pieces = spline.segments(first,last,target)
            nodes,boxes,capsules = [],[],[]
            for a,b,remainder in pieces:
                endpoints=[];errors=[]
                for t in (a,b):
                    enclosed=spline.evaluate(t)
                    point=tuple(x.mid() for x in enclosed)
                    error=_difference_upper(enclosed,tuple(_I(x) for x in point))
                    endpoints.append(point);errors.append(error)
                    self.max_trim_endpoint_enclosure=max(self.max_trim_endpoint_enclosure,error)
                p,q=endpoints
                radius=(_I(remainder)+max(errors)).hi
                if nodes and nodes[-1]!=p:
                    raise _Unsupported('B-spline pcurve subdivision endpoints disagree')
                if not nodes:nodes.append(p)
                nodes.append(q)
                boxes.append([(_I(min(p[0],q[0]))-radius).lo,(_I(min(p[1],q[1]))-radius).lo,
                              (_I(max(p[0],q[0]))+radius).hi,(_I(max(p[1],q[1]))+radius).hi])
                capsules.append((p,q,radius))
            return nodes,boxes,capsules
        second_derivative = _I(0)
        if kind == GeomAbs_Line:
            line = curve.Line()
            c, d = _vec(line.Location().Coord()), _vec(line.Direction().Coord())
            def evaluate(a, b):
                return _affine(c, (d, _I(a, b)))
            count = 1
        elif kind in (GeomAbs_Circle, GeomAbs_Ellipse):
            g = curve.Circle() if kind == GeomAbs_Circle else curve.Ellipse()
            c = _vec(g.Location().Coord())
            x, y = _vec(g.XAxis().Direction().Coord()), _vec(g.YAxis().Direction().Coord())
            ra = g.Radius() if kind == GeomAbs_Circle else g.MajorRadius()
            rb = g.Radius() if kind == GeomAbs_Circle else g.MinorRadius()
            def evaluate(a, b):
                s, co = _trig_range(a, b)
                return _affine(c, (x, co * ra), (y, s * rb))
            second_derivative = ra * _I(_norm_upper(x)) + rb * _I(_norm_upper(y))
            target_uv_error = self.delta * 0.015 / (self.lu + self.lv)
            # Bound interpolation of an arc by a chord, not its arclength.
            # Thus work grows as sqrt(radius/deviation), rather than
            # radius/deviation, for ordinary circular trims.
            count = max(8, math.ceil((last - first) * math.sqrt(
                second_derivative.hi / (8 * target_uv_error))))
            if count > 8192:
                raise _Unsupported("Trim enclosure budget exhausted")
        else:
            raise _Unsupported(f"Trim {kind.name} has no implemented conservative enclosure")
        parameters = np.linspace(first, last, count + 1)
        nodes = []
        endpoint_errors = []
        for t in parameters:
            point = evaluate(float(t), float(t))
            nominal = tuple(p.mid() for p in point)
            error = _difference_upper(point, tuple(_I(x) for x in nominal))
            self.max_trim_endpoint_enclosure = max(self.max_trim_endpoint_enclosure, error)
            endpoint_errors.append(error)
            nodes.append(nominal)
        boxes, capsules = [], []
        for i in range(count):
            dt = _I(float(parameters[i + 1])) - float(parameters[i])
            # The vector interpolation remainder is ||C''||*dt^2/8.
            # Each chord therefore has a conservative Euclidean capsule;
            # both the curve and the homotopy to the polygon lie within it.
            radius = (second_derivative * dt * dt / 8 +
                      max(endpoint_errors[i], endpoint_errors[i + 1])).hi
            a, b = nodes[i], nodes[i + 1]
            boxes.append([(_I(min(a[0], b[0])) - radius).lo,
                          (_I(min(a[1], b[1])) - radius).lo,
                          (_I(max(a[0], b[0])) + radius).hi,
                          (_I(max(a[1], b[1])) + radius).hi])
            capsules.append((a, b, radius))
        return nodes, boxes, capsules

    @staticmethod
    def _capsule_disjoint_rectangle(capsule, rectangle):
        a, b, radius = capsule
        ex, ey = _I(b[0]) - a[0], _I(b[1]) - a[1]
        dx, dy = _I(rectangle[0], rectangle[1]) - a[0], _I(rectangle[2], rectangle[3]) - a[1]
        limit = _I(radius) * _norm_upper((ex, ey))
        cross = ex * dy - ey * dx
        if cross.lo > limit.hi or cross.hi < -limit.hi:
            return True
        dot = ex * dx + ey * dy
        length2 = ex * ex + ey * ey
        return dot.hi < -limit.hi or dot.lo > (length2 + limit).hi

    @staticmethod
    def _capsule_disjoint_triangle(capsule, triangle, orientation):
        a, b, radius = capsule
        for i in range(3):
            p, q = triangle[i], triangle[(i + 1) % 3]
            ex, ey = _I(q[0]) - p[0], _I(q[1]) - p[1]
            limit = (_I(radius) * _norm_upper((ex, ey))).hi
            ca = ex * (_I(a[1]) - p[1]) - ey * (_I(a[0]) - p[0])
            cb = ex * (_I(b[1]) - p[1]) - ey * (_I(b[0]) - p[0])
            if orientation > 0 and max(ca.hi, cb.hi) < -limit:
                return True
            if orientation < 0 and min(ca.lo, cb.lo) > limit:
                return True
        ex, ey = _I(b[0]) - a[0], _I(b[1]) - a[1]
        limit = (_I(radius) * _norm_upper((ex, ey))).hi
        crosses = [ex * (_I(p[1]) - a[1]) - ey * (_I(p[0]) - a[0]) for p in triangle]
        return min(c.lo for c in crosses) > limit or max(c.hi for c in crosses) < -limit

    def classify(self, rectangle, triangle=None):
        u0, u1, v0, v1 = rectangle
        b = self.boxes
        overlaps = np.flatnonzero((b[:, 0] <= u1) & (b[:, 2] >= u0) &
                                  (b[:, 1] <= v1) & (b[:, 3] >= v0))
        orientation = _orient(*triangle) if triangle is not None else 0
        for index in overlaps:
            capsule = self.capsules[index]
            if triangle is not None and orientation:
                disjoint = self._capsule_disjoint_triangle(capsule, triangle, orientation)
            else:
                disjoint = self._capsule_disjoint_rectangle(capsule, rectangle)
            if not disjoint:
                return "boundary"
        # A triangle vertex is an exact member of the represented parameter
        # triangle; no rounded barycenter membership is assumed.
        p = triangle[0] if triangle is not None else (u0 * 0.5 + u1 * 0.5, v0 * 0.5 + v1 * 0.5)
        return "inside" if _winding(p, self.loops) else "outside"

    def _find_seed(self):
        u0, u1, v0, v1 = self.bounds
        for n in (3, 7, 15):
            for u in np.linspace(u0, u1, n + 2)[1:-1]:
                for v in np.linspace(v0, v1, n + 2)[1:-1]:
                    if self.classify((u, u, v, v)) == "inside":
                        return (float(u), float(v))
        raise _Unsupported("Could not establish an interior surface witness")

    def _first_derivative_bounds(self):
        if self.spline is not None:
            # Span-local interval derivatives avoid a sampled curvature claim.
            values=[self.spline.derivative_bounds(rect)[:2] for rect in self.spline.rectangles(self.bounds)]
            return max(v[0] for v in values),max(v[1] for v in values)
        xy = _I(self.nx) + self.ny
        if self.kind == "plane":
            return self.nx, self.ny
        if self.kind == "cylinder":
            return (self.r * xy).hi, self.nz
        if self.kind == "cone":
            radial = self.r + _I(self.bounds[2], self.bounds[3]) * self.sa
            rmax = max(abs(radial.lo), abs(radial.hi))
            return (rmax * xy).hi, (xy + self.nz).hi
        if self.kind == "sphere":
            return (self.r * xy).hi, (self.r * (xy + self.nz)).hi
        return ((_I(self.major) + self.r) * xy).hi, (self.r * (xy + self.nz)).hi

    def curvature_error(self, rectangle):
        if self.spline is not None:return self.spline.curvature_error(rectangle)
        u0, u1, v0, v1 = rectangle
        du, dv = _I(u1) - u0, _I(v1) - v0
        xy = _I(self.nx) + self.ny
        uu = uv = vv = _I(0)
        if self.kind == "cylinder":
            uu = self.r * xy
        elif self.kind == "cone":
            radial = self.r + _I(v0, v1) * self.sa
            uu = max(abs(radial.lo), abs(radial.hi)) * xy
            uv = max(abs(self.sa.lo), abs(self.sa.hi)) * xy
        elif self.kind == "sphere":
            uu = uv = self.r * xy
            vv = self.r * (xy + self.nz)
        elif self.kind == "torus":
            uu = (_I(self.major) + self.r) * xy
            uv = self.r * xy
            vv = self.r * (xy + self.nz)
        # Taylor about the barycentric mean; Popoviciu bounds coordinate
        # variances by range^2/4.  This controls interpolation on either
        # triangle of the rectangle (and arbitrary UV source triangles).
        return max(0, (uu * du * du / 8 + uv * du * dv / 4 + vv * dv * dv / 8).hi)

    def evaluate(self, uv):
        key = tuple(map(float, uv))
        cached = self._eval_cache.get(key)
        if cached is not None:
            return cached
        u, v = key
        if self.spline is not None:
            result = self.spline.evaluate(key)
        elif self.kind == "plane":
            result = _affine(self.c, (self.x, u), (self.y, v))
        else:
            su, cu = _sincos(u)
            if self.kind == "cylinder":
                result = _affine(self.c, (self.x, cu * self.r),
                                 (self.y, su * self.r), (self.z, v))
            elif self.kind == "cone":
                radius = self.r + _I(v) * self.sa
                result = _affine(self.c, (self.x, cu * radius),
                                 (self.y, su * radius), (self.z, _I(v) * self.ca))
            else:
                sv, cv = _sincos(v)
                radius = cv * self.r
                if self.kind == "torus":
                    radius = radius + self.major
                result = _affine(self.c, (self.x, cu * radius),
                                 (self.y, su * radius), (self.z, sv * self.r))
        if len(self._eval_cache) < 40000:
            self._eval_cache[key] = result
        return result

    def project(self, points):
        local = (np.asarray(points) - self.cn) @ self.inverse_frame.T
        if self.spline is not None:return self.spline.project(local)
        if self.kind == "plane":
            return local[:, :2]
        u = np.arctan2(local[:, 1], local[:, 0])
        radial = np.hypot(local[:, 0], local[:, 1])
        if self.kind in ("cylinder", "cone"):
            v = local[:, 2]
            if self.kind == "cone":
                v = v * self.ca.mid() + (radial - self.r) * self.sa.mid()
        elif self.kind == "sphere":
            v = np.arctan2(local[:, 2], radial)
        else:
            v = np.arctan2(local[:, 2], radial - self.major)
        result = np.column_stack((u, v))
        for axis, periodic in ((0, True), (1, self.kind == "torus")):
            if not periodic:
                continue
            low, high = self.bounds[2 * axis:2 * axis + 2]
            center = (low + high) * 0.5
            values = result[:, axis]
            values += np.round((center - values) / (2 * math.pi)) * (2 * math.pi)
            # Keep a small source triangle on a consistent side of a seam.
            if np.ptp(values) > math.pi:
                trial = values.copy()
                trial[trial < center] += 2 * math.pi
                if np.min(trial) >= low - 1e-12 and np.max(trial) <= high + 1e-12:
                    values[:] = trial
                else:
                    trial = values.copy()
                    trial[trial > center] -= 2 * math.pi
                    if np.min(trial) >= low - 1e-12 and np.max(trial) <= high + 1e-12:
                        values[:] = trial
        return result

    def source_bound(self, vertices):
        nominal = np.array([[x.mid() for x in p] for p in vertices])
        uv = self.project(nominal)
        u0, u1, v0, v1 = self.bounds
        # Moving projected parameters inward is an explicit affine map, not
        # a claim that the source vertices lie on the surface.  Endpoint
        # residuals below include the complete displacement.
        eu = max(1024 * _EPS * max(1, abs(u0), abs(u1)), self.delta * 1e-7 / self.lu)
        ev = max(1024 * _EPS * max(1, abs(v0), abs(v1)), self.delta * 1e-7 / self.lv)
        uv[:, 0] = np.clip(uv[:, 0], min(u0 + eu, (u0 + u1) / 2), max(u1 - eu, (u0 + u1) / 2))
        uv[:, 1] = np.clip(uv[:, 1], min(v0 + ev, (v0 + v1) / 2), max(v1 - ev, (v0 + v1) / 2))
        rectangle = (float(uv[:, 0].min()), float(uv[:, 0].max()),
                     float(uv[:, 1].min()), float(uv[:, 1].max()))
        best = _INF
        for attempt in range(2):
            if attempt:
                extent = np.max(np.sum(np.abs(uv - self.seed) * self.metric, axis=1))
                fraction = min(0.05, self.delta * 0.04 / max(extent, 1e-30))
                uv = uv * (1 - fraction) + np.asarray(self.seed) * fraction
                rectangle = (float(uv[:, 0].min()), float(uv[:, 0].max()),
                             float(uv[:, 1].min()), float(uv[:, 1].max()))
            if self.classify(rectangle, triangle=uv) == "inside":
                residual = max(_difference_upper(p, self.evaluate(q)) for p, q in zip(vertices, uv))
                best = min(best, _up(residual + self.curvature_error(rectangle)))
                if best <= self.delta:
                    return best
        # A single proven interior witness also bounds the entire source
        # triangle by convexity of distance to that fixed point.
        center = nominal.mean(axis=0)
        projected = self.project(center[None, :])[0]
        candidates = [tuple(projected), self.seed]
        _, indices = self.boundary_tree.query(projected * self.metric,
                                               k=min(3, len(self.boxes)))
        for index in np.atleast_1d(indices):
            b = self.boxes[index]
            bc = self.boundary_centers[index]
            step = np.maximum((b[2:] - b[:2]) * 1.5,
                              self.delta * 0.16 / self.metric)
            for direction in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                candidates.append(tuple(bc + step * direction))
        for q in candidates:
            if not (u0 <= q[0] <= u1 and v0 <= q[1] <= v1):
                continue
            if self.classify((q[0], q[0], q[1], q[1])) != "inside":
                continue
            point = self.evaluate(q)
            bound = max(_difference_upper(p, point) for p in vertices)
            best = min(best, bound)
        return best


class _Mesh:
    def __init__(self, triangles):
        self.triangles = triangles

    def candidates(self, point):
        # Centroid-nearest selection can miss a very long narrow triangle
        # whose interior contains the query.  Compute approximate triangle
        # distances to choose witnesses; no accuracy claim relies on this
        # floating point ranking (point_bound verifies feasibility).
        distance2 = triangle_distances(point, self.triangles, witnesses=False)
        count = min(4, len(distance2))
        return np.argpartition(distance2, count - 1)[:count]

    @staticmethod
    def point_bound(point, triangle):
        """Upper distance to a feasible barycentric point of the triangle.

        Projection calculations only choose weights.  Clipped nonnegative
        weights, interpreted as exact floats and normalized with intervals,
        establish membership independently of the optimizer's accuracy.
        """
        p = np.array([x.mid() for x in point])
        a, b, c = triangle
        ab, ac = b - a, c - a
        d00, d01, d11 = np.dot(ab, ab), np.dot(ab, ac), np.dot(ac, ac)
        ap = p - a
        denominator = d00 * d11 - d01 * d01
        weights = []
        if denominator > 0 and math.isfinite(denominator):
            d20, d21 = np.dot(ap, ab), np.dot(ap, ac)
            v = (d11 * d20 - d01 * d21) / denominator
            w = (d00 * d21 - d01 * d20) / denominator
            if v >= 0 and w >= 0 and v + w <= 1:
                weights.append(np.array([1 - v - w, v, w]))
        # Segment candidates also handle degeneracies, very thin triangles,
        # and a projection outside the triangle.
        for i, j in ((0, 1), (1, 2), (2, 0)):
            edge = triangle[j] - triangle[i]
            length2 = np.dot(edge, edge)
            t = float(np.clip(np.dot(p - triangle[i], edge) / length2, 0, 1)) if length2 > 0 else 0.0
            bary = np.zeros(3)
            bary[i], bary[j] = 1 - t, t
            weights.append(bary)
        best = _INF
        for bary in weights:
            bary = np.maximum(bary, 0)
            denominator_i = sum((_I(float(x)) for x in bary), _I(0))
            if denominator_i.lo <= 0:
                continue
            witness = tuple(sum((_I(float(bary[j])) * float(triangle[j, i]) for j in range(3)),
                                _I(0)) / denominator_i for i in range(3))
            best = min(best, _difference_upper(point, witness))
        return best

    def rectangle_bound(self, face, rectangle):
        u0, u1, v0, v1 = rectangle
        uv = ((u0, v0), (u1, v0), (u1, v1), (u0, v1))
        points = [face.evaluate(q) for q in uv]
        curvature = face.curvature_error(rectangle)
        best_cover = _INF
        residual_cache = {}
        # Both diagonals cover exactly the same rectangle.  Trying both
        # avoids refining an entire flat face merely because the reference
        # triangulator chose the other diagonal.
        for cover in (((0, 1, 2), (0, 2, 3)), ((0, 1, 3), (1, 2, 3))):
            bound = 0.0
            for indices in cover:
                center = np.mean([[x.mid() for x in points[i]] for i in indices], axis=0)
                best = _INF
                for ti in self.candidates(center):
                    triangle = self.triangles[ti]
                    for i in indices:
                        key = (i, int(ti))
                        if key not in residual_cache:
                            residual_cache[key] = self.point_bound(points[i], triangle)
                    residual = max(residual_cache[(i, int(ti))] for i in indices)
                    best = min(best, residual)
                bound = max(bound, best)
            best_cover = min(best_cover, bound)
            if _up(best_cover + curvature) <= face.delta:
                break
        return _up(best_cover + curvature)


def _source_vertices(original, bary):
    return [tuple(sum((_I(float(weights[j])) * float(original[j, i]) for j in range(3)),
                      _I(0)) for i in range(3)) for weights in bary]


def _deviation(upper, cells, completed, margin):
    return {"lower_bound": 0.0,
            "upper_bound": _up(upper + margin) if math.isfinite(upper) else None,
            "verification": "bounded" if completed else "unverified",
            "method": "native_parameter_domain_interpolation_enclosure",
            "processed_cells": cells,
            "complete": completed}


def verify(mesh_triangles, shape, max_deviation, *, max_cells=100000,
           arithmetic_margin=0.0, **_metadata) -> dict[str, Any]:
    """Bound both directed distances; fail closed on unsupported/incomplete work.

    ``max_cells`` is the combined adaptive-cell budget.  ``arithmetic_margin``
    is additional physical padding, never a replacement for interval bounds.
    It is subtracted from the working acceptance threshold and reported.
    Metadata kwargs are accepted for the assembly integration; topology and
    material obligations are deliberately the caller's responsibility.
    """
    triangles = np.asarray(mesh_triangles, dtype=np.float64)
    if triangles.ndim != 3 or triangles.shape[1:] != (3, 3) or not len(triangles):
        raise ValueError("mesh_triangles must be a nonempty [N,3,3] array")
    if not np.isfinite(triangles).all():
        raise ValueError("mesh_triangles must contain finite coordinates")
    if not math.isfinite(max_deviation) or max_deviation < 0:
        raise ValueError("max_deviation must be finite and nonnegative")
    if not math.isfinite(arithmetic_margin) or arithmetic_margin < 0:
        raise ValueError("arithmetic_margin must be finite and nonnegative")
    if isinstance(max_cells, bool) or not isinstance(max_cells, int) or max_cells < 1:
        raise ValueError("max_cells must be a positive integer")
    report = {
        "source_to_result_deviation": _deviation(_INF, 0, False, arithmetic_margin),
        "result_to_source_deviation": _deviation(_INF, 0, False, arithmetic_margin),
        "error_verification_method": {
            "name": "adaptive_native_domain_enclosures",
            "arithmetic": "IEEE-754 binary64 outward nextafter rounding; enclosed Taylor sin/cos; exact filtered orientation",
            "arithmetic_margin": arithmetic_margin,
            "reference": "original supplied triangle surface set",
            "tested_result": "OCCT analytic or positive-weight nonperiodic spline support surfaces restricted by nominal UV trim wires",
            "topology_and_material_verified": False,
            "lower_bounds": "zero (no infeasibility claim from upper-bound failure)",
            "supported_surfaces": ["plane", "cylinder", "cone", "sphere", "torus", "nonperiodic_bspline", "bezier"],
            "supported_trims": ["line", "circle", "ellipse", "nonperiodic_bspline", "bezier"],
            "representation_assumption": "caller checks native BRep/pcurve validity; UV endpoint gaps may close only within 512 binary64 eps of UV coordinate scale",
        },
    }
    def failure(message, code="INSUFFICIENT_VERIFICATION"):
        return {"accepted": False, "report": report,
                "issues": [{"code": code, "explanation": message}]}
    working = _down(max_deviation - arithmetic_margin)
    if working <= 0:
        return failure("Arithmetic padding exhausts the deviation allowance")
    if (sys.float_info.radix != 2 or sys.float_info.mant_dig != 53 or
            math.nextafter(0.0, 1.0) != float.fromhex('0x0.0000000000001p-1022') or
            float.fromhex('0x0.0000000000001p-1022') * 2 != float.fromhex('0x0.0000000000002p-1022')):
        return failure("This arithmetic enclosure requires IEEE-754 binary64 with gradual underflow")
    try:
        native_faces = shape.Faces()
        if not native_faces:
            return failure("Result has no finite boundary faces")
        if len(triangles) + len(native_faces) > max_cells:
            return failure("Root domain cells exceed the verification cell budget")
        faces = [_Face(f, working) for f in native_faces]
        report["error_verification_method"]["max_uv_endpoint_closure"] = max(f.max_trim_closure for f in faces)
        trim_padding = max(f.trim_padding for f in faces)
        report["error_verification_method"]["trim_endpoint_physical_padding"] = trim_padding
        arithmetic_margin = _up(arithmetic_margin + trim_padding)
        working = _down(max_deviation - arithmetic_margin)
        if working <= 0:
            return failure("Trim endpoint arithmetic padding exhausts the deviation allowance")
        mesh = _Mesh(triangles)
        serial = 0
        used = 0
        source_heap = []
        accepted_source_upper = 0.0
        def source_bound(vertices, preferred=0):
            # Each face supplies an independently valid upper bound on distance
            # to the entire result. One bound below the allowance is enough;
            # evaluating every other face cannot strengthen the pass decision.
            # Reuse the parent's useful face first for adaptive children.
            best, selected = _INF, preferred
            for fi in (preferred, *(i for i in range(len(faces)) if i != preferred)):
                upper = faces[fi].source_bound(vertices)
                if upper < best:
                    best, selected = upper, fi
                if best <= working:
                    break
            return best, selected
        # Every root is bounded before adaptive work starts, so even an
        # exhausted budget leaves an honest (possibly loose) global upper.
        for ti, original in enumerate(triangles):
            bary = np.eye(3)
            vertices = _source_vertices(original, bary)
            used += 1
            upper, preferred = source_bound(vertices)
            serial += 1
            heapq.heappush(source_heap, (-upper, serial, ti, bary, 0, preferred))
        while source_heap:
            upper = -source_heap[0][0]
            if upper <= working:
                accepted_source_upper = max(accepted_source_upper, upper)
                source_heap.clear()
                break
            if used >= max_cells:
                report["source_to_result_deviation"] = _deviation(max(accepted_source_upper, upper), used, False, arithmetic_margin)
                return failure("Source-to-result adaptive verification cell budget exhausted")
            _, _, ti, bary, depth, preferred = heapq.heappop(source_heap)
            if used + 2 > max_cells:
                report["source_to_result_deviation"] = _deviation(max(accepted_source_upper, upper), used, False, arithmetic_margin)
                return failure("Source-to-result adaptive verification cell budget exhausted")
            if depth >= 40:
                report["source_to_result_deviation"] = _deviation(max(accepted_source_upper, upper), used, False, arithmetic_margin)
                return failure("Source subdivision reached its exact dyadic parameter limit")
            original = triangles[ti]
            nominal = bary @ original
            lengths = [np.linalg.norm(nominal[j] - nominal[i]) for i, j in ((0, 1), (1, 2), (2, 0))]
            i, j = ((0, 1), (1, 2), (2, 0))[int(np.argmax(lengths))]
            midpoint = (bary[i] + bary[j]) * 0.5
            for replace in (i, j):
                child = bary.copy()
                child[replace] = midpoint
                vertices = _source_vertices(original, child)
                used += 1
                child_upper, child_preferred = source_bound(vertices, preferred)
                if child_upper <= working:
                    accepted_source_upper = max(accepted_source_upper, child_upper)
                else:
                    serial += 1
                    heapq.heappush(source_heap, (-child_upper, serial, ti, child, depth + 1, child_preferred))
        report["source_to_result_deviation"] = _deviation(accepted_source_upper, used, True, arithmetic_margin)
        result_heap = []
        accepted_result_upper = 0.0
        source_used = used
        for fi, face in enumerate(faces):
            roots = face.spline.rectangles(face.bounds) if face.spline is not None else [face.bounds]
            for rectangle in roots:
                if used >= max_cells:
                    return failure("Result root domain cells exceed the remaining verification budget")
                used += 1
                if face.classify(rectangle) == "outside":
                    continue
                upper = mesh.rectangle_bound(face, rectangle)
                serial += 1
                heapq.heappush(result_heap, (-upper, serial, fi, rectangle, 0))
        while result_heap:
            upper = -result_heap[0][0]
            if upper <= working:
                accepted_result_upper = max(accepted_result_upper, upper)
                result_heap.clear()
                break
            if used >= max_cells:
                report["result_to_source_deviation"] = _deviation(max(accepted_result_upper, upper), used - source_used, False, arithmetic_margin)
                return failure("Result-to-source adaptive verification cell budget exhausted")
            _, _, fi, rectangle, depth = heapq.heappop(result_heap)
            if used + 2 > max_cells:
                report["result_to_source_deviation"] = _deviation(max(accepted_result_upper, upper), used - source_used, False, arithmetic_margin)
                return failure("Result-to-source adaptive verification cell budget exhausted")
            face = faces[fi]
            u0, u1, v0, v1 = rectangle
            if depth >= 60:
                return failure(f"Result parameter subdivision reached its precision limit: {face.kind} {rectangle} upper={upper}")
            if (u1 - u0) * face.lu >= (v1 - v0) * face.lv:
                mid = u0 * 0.5 + u1 * 0.5
                children = ((u0, mid, v0, v1), (mid, u1, v0, v1))
                if mid in (u0, u1):
                    return failure("Result parameter subdivision cannot make progress")
            else:
                mid = v0 * 0.5 + v1 * 0.5
                children = ((u0, u1, v0, mid), (u0, u1, mid, v1))
                if mid in (v0, v1):
                    return failure("Result parameter subdivision cannot make progress")
            for child in children:
                used += 1
                if face.classify(child) == "outside":
                    continue
                child_upper = mesh.rectangle_bound(face, child)
                if child_upper <= working:
                    accepted_result_upper = max(accepted_result_upper, child_upper)
                else:
                    serial += 1
                    heapq.heappush(result_heap, (-child_upper, serial, fi, child, depth + 1))
        report["result_to_source_deviation"] = _deviation(accepted_result_upper, used - source_used, True, arithmetic_margin)
        if any(report[key]["upper_bound"] > max_deviation for key in
               ("source_to_result_deviation", "result_to_source_deviation")):
            return failure("Final outward rounding leaves the threshold unresolved")
        return {"accepted": True, "report": report, "issues": []}
    except (_Unsupported, ArithmeticError, OverflowError) as error:
        return failure(str(error))
    except Exception as error:
        # Native geometric operations may raise several OCCT exception
        # classes.  An unexpected kernel failure cannot authorize delivery.
        return failure(f"Verification operation failed ({type(error).__name__}): {error}")
