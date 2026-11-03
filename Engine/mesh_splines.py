"""Outward interval enclosures of native nonperiodic rational B-splines.

The original OCCT poles, positive weights and expanded knots are the tested
representation. No knot insertion, meshing deflection, or sampled fit is used
as a geometric certificate. Interval de Boor evaluates homogeneous coordinates;
derivative control nets and the rational quotient identities enclose first and
second derivatives. C0 knot lines are explicit chart boundaries.
"""
from __future__ import annotations

from bisect import bisect_right
from collections import Counter
import math

import numpy as np

from mesh_bounds import _I, _norm_upper, _Unsupported


def _union(values):
    return tuple(_I(min(value[i].lo for value in values), max(value[i].hi for value in values))
                 for i in range(len(values[0])))


def _zero(dimension):
    return tuple(_I(0) for _ in range(dimension))


def _finite_control(value):
    if not math.isfinite(value.lo) or not math.isfinite(value.hi):
        raise _Unsupported('B-spline homogeneous coefficient exceeds arithmetic range')
    return value


def _clip_hull(value, controls):
    """Intersect with the positive partition-of-unity control hull."""
    bounds=_union(controls)
    return tuple(_I(max(a.lo,b.lo),min(a.hi,b.hi)) for a,b in zip(value,bounds))


def _span(knots, degree, count, parameter):
    return max(degree, min(count - 1, bisect_right(knots, parameter) - 1))


def _deboor(values, knots, degree, parameter, span):
    """The selected polynomial span, including conservative tiny extrapolation."""
    work = [tuple(value) for value in values[span-degree:span+1]]
    for level in range(1, degree+1):
        for j in range(degree, level-1, -1):
            index = span-degree+j
            denominator = _I(knots[index+degree-level+1])-knots[index]
            if denominator.lo <= 0:
                raise _Unsupported('Singular B-spline span denominator')
            alpha = (parameter-knots[index])/denominator
            work[j] = tuple((1-alpha)*a+alpha*b for a,b in zip(work[j-1],work[j]))
    return work[degree]


def _pieces(knots, degree, count, low, high):
    # Include the end knots as well. Trim capsules can extend a few ulps beyond
    # the native parameter interval; isolate that extrapolation from the
    # positive-weight partition-of-unity enclosure in the interior.
    boundaries = sorted({low, high, *(k for k in knots if low < k < high)})
    if low == high:
        return [(low, high, _span(knots, degree, count, low))]
    return [(a,b,_span(knots,degree,count,a)) for a,b in zip(boundaries,boundaries[1:])]


def _differentiate(control, knots, degree, axis=0):
    """Differentiate a homogeneous curve or tensor net without changing input."""
    moved = np.moveaxis(control, axis, 0)
    if degree == 0:
        shape = list(moved.shape);shape[0] = 1
        result = np.empty(shape,dtype=object)
        for index in np.ndindex(*shape):result[index]=_I(0)
        return np.moveaxis(result,0,axis),[knots[0],knots[-1]],0
    result = np.empty((len(moved)-1, *moved.shape[1:]),dtype=object)
    for i in range(len(moved)-1):
        width = _I(knots[i+degree+1])-knots[i+1]
        if width.lo <= 0 and knots[i+degree+1] != knots[i+1]:
            raise _Unsupported('B-spline derivative knot spacing is below arithmetic resolution')
        for other in np.ndindex(*moved.shape[1:]):
            result[(i,*other)] = (_I(degree)*(moved[(i+1,*other)]-moved[(i,*other)])/width
                                  if width.lo > 0 else _I(0))
    return np.moveaxis(result,0,axis),knots[1:-1],degree-1


def _expanded(native):
    return [float(native.Value(i)) for i in range(native.Lower(),native.Upper()+1)]


def _validate_knots(knots, degree, count):
    if not 1 <= degree <= 16 or count < degree+1 or len(knots) != count+degree+1:
        raise _Unsupported('Unsupported B-spline degree/control/expanded-knot dimensions')
    if any(not math.isfinite(k) for k in knots) or any(a>b for a,b in zip(knots,knots[1:])):
        raise _Unsupported('Invalid B-spline knots')
    if knots[degree] >= knots[count]:
        raise _Unsupported('Empty B-spline parameter interval')
    multiplicity=Counter(knots)
    if any(multiplicity[k]>degree for k in set(knots[degree+1:count])):
        raise _Unsupported('Discontinuous B-spline support')


class SplineCurve2D:
    def __init__(self, curve, bezier=False):
        if not bezier and curve.IsPeriodic():
            raise _Unsupported('Periodic B-spline pcurve enclosure is unavailable')
        self.degree = curve.Degree()
        count = curve.NbPoles()
        self.knots = [0.]*(self.degree+1)+[1.]*(self.degree+1) if bezier else _expanded(curve.KnotSequence())
        _validate_knots(self.knots,self.degree,count)
        if count>8192:raise _Unsupported('B-spline pcurve pole budget exhausted')
        self.control = np.empty((count,3),dtype=object)
        weights=[]
        for i in range(count):
            weight = curve.Weight(i+1)
            if not math.isfinite(weight) or weight<=0:raise _Unsupported('Pcurve weights must be finite and positive')
            p = curve.Pole(i+1)
            for j,value in enumerate(p.Coord()):self.control[i,j]=_finite_control(_I(value)*weight)
            self.control[i,2]=_I(weight)
            weights.append(weight)
        self.uniform_weight=weights[0] if all(w==weights[0] for w in weights) else None
        first,k1,p1 = _differentiate(self.control,self.knots,self.degree)
        second,k2,p2 = _differentiate(first,k1,p1)
        self.derivatives = [(self.control,self.knots,self.degree),(first,k1,p1),(second,k2,p2)]

    def _hull(self, order, low, high):
        values,knots,degree = self.derivatives[order]
        pieces=[]
        for a,b,span in _pieces(knots,degree,len(values),low,high):
            value=_deboor(values,knots,degree,_I(a,b),span)
            if a>=knots[degree] and b<=knots[len(values)]:
                value=_clip_hull(value,values[span-degree:span+1])
            pieces.append(value)
        value=_union(pieces)
        if self.uniform_weight is not None:value=(*value[:-1],_I(self.uniform_weight if order==0 else 0))
        return value

    def evaluate(self, low, high=None):
        high = low if high is None else high
        h = self._hull(0,low,high)
        if h[-1].lo<=0:raise _Unsupported('Pcurve rational denominator enclosure crosses zero')
        return tuple(value/h[-1] for value in h[:-1])

    def second_bound(self, low, high):
        h,d,dd = [self._hull(order,low,high) for order in range(3)]
        w=h[-1]
        if w.lo<=0:raise _Unsupported('Pcurve rational denominator enclosure crosses zero')
        value=tuple(a/w for a in h[:-1])
        first=tuple((a-s*d[-1])/w for a,s in zip(d[:-1],value))
        second=tuple((a-s*dd[-1]-2*t*d[-1])/w for a,s,t in zip(dd[:-1],value,first))
        return _norm_upper(second)

    def segments(self, first, last, target, maximum=8192):
        """Knot-aware intervals with a conservative chord interpolation error."""
        roots=_pieces(self.knots,self.degree,len(self.control),first,last)
        todo=[(a,b) for a,b,_ in reversed(roots)];result=[]
        while todo:
            if len(result)+len(todo)>maximum:raise _Unsupported('B-spline trim enclosure budget exhausted')
            a,b=todo.pop()
            width=_I(b)-a
            try:error=(_I(self.second_bound(a,b))*width*width/8).hi
            except _Unsupported:error=math.inf
            if error>target:
                mid=a*.5+b*.5
                if mid in (a,b):raise _Unsupported('B-spline trim subdivision reached precision limit')
                todo.extend([(mid,b),(a,mid)])
            else:result.append((a,b,error))
        return result


class SplineSurface:
    def __init__(self, surface, transform, bezier=False):
        if not bezier and (surface.IsUPeriodic() or surface.IsVPeriodic()):
            raise _Unsupported('Periodic B-spline surface enclosure is unavailable')
        self.raw = surface
        self.degree=(surface.UDegree(),surface.VDegree())
        count=(surface.NbUPoles(),surface.NbVPoles())
        self.knots=([0.]*(self.degree[0]+1)+[1.]*(self.degree[0]+1),
                    [0.]*(self.degree[1]+1)+[1.]*(self.degree[1]+1)) if bezier else (
                        _expanded(surface.UKnotSequence()),_expanded(surface.VKnotSequence()))
        for k,p,n in zip(self.knots,self.degree,count):_validate_knots(k,p,n)
        if count[0]*count[1]>65536:raise _Unsupported('B-spline surface pole budget exhausted')
        self.control=np.empty((*count,4),dtype=object)
        weights=[]
        for i in range(count[0]):
            for j in range(count[1]):
                weight=surface.Weight(i+1,j+1)
                if not math.isfinite(weight) or weight<=0:raise _Unsupported('Surface weights must be finite and positive')
                point=transform(surface.Pole(i+1,j+1).Coord(),True)
                for k,value in enumerate(point):self.control[i,j,k]=_finite_control(value*weight)
                self.control[i,j,3]=_I(weight)
                weights.append(weight)
        self.uniform_weight=weights[0] if all(w==weights[0] for w in weights) else None
        self.bounds=(self.knots[0][self.degree[0]],self.knots[0][count[0]],
                     self.knots[1][self.degree[1]],self.knots[1][count[1]])
        self.nets={(0,0):(self.control,self.knots,self.degree)}
        for orders in [(1,0),(0,1),(2,0),(1,1),(0,2)]:
            axis=0 if orders[0] else 1
            prior=(orders[0]-1,orders[1]) if axis==0 else (orders[0],orders[1]-1)
            net,knots,degree=self.nets[prior]
            derivative,k,p=_differentiate(net,knots[axis],degree[axis],axis)
            new_knots=list(knots);new_knots[axis]=k
            new_degree=list(degree);new_degree[axis]=p
            self.nets[orders]=(derivative,tuple(new_knots),tuple(new_degree))
        self.c0=tuple([k for k,multiplicity in sorted(Counter(values[p+1:n]).items()) if multiplicity>=p]
                      for values,p,n in zip(self.knots,self.degree,count))
        # Only a heuristic projection initializer; interval checks authorize all
        # witnesses and bounds independently of native projection convergence.
        self.inverse=transform
        self._projector=None
        self._projection_seed=None

    def _hull(self, orders, rectangle, controls_only=False):
        net,knots,degree=self.nets[orders]
        u0,u1,v0,v1=rectangle
        values=[]
        for a,b,uspan in _pieces(knots[0],degree[0],len(net),u0,u1):
            for c,d,vspan in _pieces(knots[1],degree[1],net.shape[1],v0,v1):
                inside=(a>=knots[0][degree[0]] and b<=knots[0][len(net)] and
                        c>=knots[1][degree[1]] and d<=knots[1][net.shape[1]])
                active=net[uspan-degree[0]:uspan+1,vspan-degree[1]:vspan+1].reshape(-1,4)
                if controls_only and inside:
                    # Derivative control nets already enclose their complete
                    # polynomial span. This avoids interval dependency growth
                    # and repeated de Boor work when only a norm is required.
                    values.append(_union(active))
                    continue
                columns=[]
                for j in range(vspan-degree[1],vspan+1):
                    column=_deboor(net[:,j,:],knots[0],degree[0],_I(a,b),uspan)
                    if a>=knots[0][degree[0]] and b<=knots[0][len(net)]:
                        column=_clip_hull(column,net[uspan-degree[0]:uspan+1,j,:])
                    columns.append(column)
                # This local V net has an artificial span index degree, with
                # its exact original knot window retained for de Boor.
                vk=knots[1][vspan-degree[1]:vspan+degree[1]+2]
                value=_deboor(columns,vk,degree[1],_I(c,d),degree[1])
                if c>=knots[1][degree[1]] and d<=knots[1][net.shape[1]]:
                    value=_clip_hull(value,columns)
                if inside:
                    value=_clip_hull(value,active)
                values.append(value)
        value=_union(values)
        if self.uniform_weight is not None:value=(*value[:-1],_I(self.uniform_weight if orders==(0,0) else 0))
        return value

    def evaluate(self, uv):
        u,v=uv;h=self._hull((0,0),(u,u,v,v))
        if h[-1].lo<=0:raise _Unsupported('Surface rational denominator enclosure crosses zero')
        return tuple(value/h[-1] for value in h[:-1])

    def project(self, points):
        from OCP.GeomAPI import GeomAPI_ProjectPointOnSurf
        from OCP.gp import gp_Pnt
        if self._projector is None:
            self._projector=GeomAPI_ProjectPointOnSurf()
            self._projector.Init(self.raw,*self.bounds,1e-9)
        result=[]
        for point in points:
            try:
                self._projector.Perform(gp_Pnt(*map(float,point)))
                if not self._projector.IsDone() or not self._projector.NbPoints():raise ValueError('No projection')
                uv=self._projector.LowerDistanceParameters()
            except Exception:
                if self._projection_seed is None:
                    coordinates=[];values=[]
                    for rect in self.rectangles(self.bounds):
                        for u in np.linspace(rect[0],rect[1],3):
                            for v in np.linspace(rect[2],rect[3],3):
                                coordinates.append((float(u),float(v)));values.append(self.raw.Value(float(u),float(v)).Coord())
                    self._projection_seed=np.asarray(coordinates),np.asarray(values)
                coords,values=self._projection_seed
                uv=coords[int(np.argmin(np.sum((values-point)**2,axis=1)))]
            result.append(uv)
        return np.asarray(result,dtype=float)

    def derivative_bounds(self, rectangle):
        hull=lambda order:self._hull(order,rectangle,controls_only=True)
        h=hull((0,0));w=h[-1]
        if w.lo<=0:raise _Unsupported('Surface rational denominator enclosure crosses zero')
        s=tuple(value/w for value in h[:-1])
        hu,hv=[hull(order) for order in [(1,0),(0,1)]]
        su=tuple((a-x*hu[-1])/w for a,x in zip(hu[:-1],s))
        sv=tuple((a-x*hv[-1])/w for a,x in zip(hv[:-1],s))
        huu,huv,hvv=[hull(order) for order in [(2,0),(1,1),(0,2)]]
        suu=tuple((a-x*huu[-1]-2*y*hu[-1])/w for a,x,y in zip(huu[:-1],s,su))
        suv=tuple((a-x*huv[-1]-y*hv[-1]-z*hu[-1])/w for a,x,y,z in zip(huv[:-1],s,su,sv))
        svv=tuple((a-x*hvv[-1]-2*y*hv[-1])/w for a,x,y in zip(hvv[:-1],s,sv))
        return tuple(map(_norm_upper,(su,sv,suu,suv,svv)))

    def curvature_error(self, rectangle):
        u0,u1,v0,v1=rectangle
        if any(u0<k<u1 for k in self.c0[0]) or any(v0<k<v1 for k in self.c0[1]):return math.inf
        try:_,_,uu,uv,vv=self.derivative_bounds(rectangle)
        except _Unsupported:return math.inf
        du,dv=_I(u1)-u0,_I(v1)-v0
        return (_I(uu)*du*du/8+_I(uv)*du*dv/4+_I(vv)*dv*dv/8).hi

    def rectangles(self, rectangle):
        u0,u1,v0,v1=rectangle
        us=sorted({u0,u1,*(k for k in self.knots[0] if u0<k<u1)})
        vs=sorted({v0,v1,*(k for k in self.knots[1] if v0<k<v1)})
        if (len(us)-1)*(len(vs)-1)>4096:raise _Unsupported('B-spline knot-chart budget exhausted')
        return [(a,b,c,d) for a,b in zip(us,us[1:]) for c,d in zip(vs,vs[1:])]
