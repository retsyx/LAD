"""Independent native-value and geometric checks for rational spline bounds."""
from pathlib import Path
import sys
import unittest
import numpy as np
import cadquery as cq
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from mesh_bounds import _Face, verify
from mesh_splines import SplineCurve2D
from OCP.BRepAdaptor import BRepAdaptor_Surface
from OCP.BRep import BRep_Tool
from OCP.BRepBuilderAPI import BRepBuilderAPI_MakeFace
from OCP.Geom import Geom_BezierSurface, Geom_SurfaceOfLinearExtrusion
from OCP.Geom2d import Geom2d_BezierCurve, Geom2d_BSplineCurve
from OCP.gp import gp_Pnt, gp_Pnt2d, gp_Dir, gp_Vec, gp_Vec2d
from OCP.TColgp import TColgp_Array2OfPnt, TColgp_Array1OfPnt2d
from OCP.TColStd import TColStd_Array2OfReal, TColStd_Array1OfReal, TColStd_Array1OfInteger


def rational_face():
    poles=TColgp_Array2OfPnt(1,3,1,3);weights=TColStd_Array2OfReal(1,3,1,3)
    for i in range(1,4):
        for j in range(1,4):
            poles.SetValue(i,j,gp_Pnt(i-1,j-1,.5 if i==j==2 else 0))
            weights.SetValue(i,j,.8 if i==j==2 else 1)
    surface=Geom_BezierSurface(poles,weights)
    return cq.Face(BRepBuilderAPI_MakeFace(surface,1e-9).Face())


def triangles(shape):
    points,indices=shape.tessellate(.02,.25)
    return np.asarray([[points[i].toTuple() for i in t] for t in indices])


def unsupported_extrusion():
    edge=cq.Edge.makeSpline([cq.Vector(0,0,0),cq.Vector(1,0,.5),cq.Vector(2,0,0)])
    from OCP.BRepAdaptor import BRepAdaptor_Curve
    curve=BRepAdaptor_Curve(edge.wrapped).BSpline()
    surface=Geom_SurfaceOfLinearExtrusion(curve,gp_Dir(0,1,0))
    return cq.Face(BRepBuilderAPI_MakeFace(surface,curve.FirstParameter(),curve.LastParameter(),0,2,1e-9).Face())


def helical_sweep():
    """Direct native swept/trimmed fixture, independent of reconstruction tools."""
    import math
    from OCP.BRepLib import BRepLib

    profile = [[r / 10, z / 2] for r, z in [
        [28.98494914, .5411508531], [31.22310103, 1.8333473969],
        [31.22310103, 2.1666525946], [28.98494914, 3.4588491383]]]
    pitch = height = 2
    start = math.floor((-max(p[1] for p in profile) - pitch) / pitch) * pitch
    stop = math.ceil((height - min(p[1] for p in profile) + pitch) / pitch) * pitch
    radius = (min(p[0] for p in profile) + max(p[0] for p in profile)) / 2
    path = cq.Wire.makeHelix(pitch, stop - start, radius, center=(0, 0, start))
    plane = cq.Plane(origin=(0, 0, start), xDir=(1, 0, 0), normal=(0, -1, 0))
    wire = cq.Wire.makePolygon([plane.toWorldCoords(tuple(p)) for p in profile], close=True)
    swept = cq.Solid.sweep(wire, [], path, makeSolid=True, isFrenet=True)
    bound = max(p[0] for p in profile) + pitch + height
    slab = cq.Solid.makeBox(2 * bound, 2 * bound, height, (-bound, -bound, 0))
    shape = swept.intersect(slab).located(cq.Location(cq.Vector(0, 0, -40)))
    BRepLib.SameParameter_s(shape.wrapped, 1e-7, True)
    return shape


class SplineVerificationTests(unittest.TestCase):
    def test_polynomial_surface_point_enclosures_include_native_values(self):
        shape=cq.Face.makeSplineApprox([[cq.Vector(x,y,.2*x*y) for y in (0,1,2)] for x in (0,1,2)])
        prepared=_Face(shape,.1);native=BRep_Tool.Surface_s(shape.wrapped)
        for u,v in np.random.default_rng(904).uniform(.01,.99,(30,2)):
            enclosure=prepared.evaluate((u,v));value=native.Value(u,v).Coord()
            for item,coordinate in zip(enclosure,value):
                self.assertLessEqual(item.lo,coordinate);self.assertGreaterEqual(item.hi,coordinate)
        result=verify(triangles(shape),shape,.15,max_cells=5000)
        self.assertTrue(result['accepted'],result)

    def test_positive_rational_surface_has_bounded_success_and_native_point_enclosures(self):
        shape=rational_face();prepared=_Face(shape,.2);native=BRep_Tool.Surface_s(shape.wrapped)
        for u,v in np.random.default_rng(411).uniform(.05,.95,(12,2)):
            for item,coordinate in zip(prepared.evaluate((u,v)),native.Value(u,v).Coord()):
                self.assertLessEqual(item.lo,coordinate);self.assertGreaterEqual(item.hi,coordinate)
        result=verify(triangles(shape),shape,.3,max_cells=10000)
        self.assertTrue(result['accepted'],result)
        self.assertLessEqual(result['report']['result_to_source_deviation']['upper_bound'],.3)

    def test_interior_spline_bulge_cannot_pass_using_corner_witnesses(self):
        shape=rational_face()
        mesh=np.asarray([[[0,0,0],[2,0,0],[2,2,0]],[[0,0,0],[2,2,0],[0,2,0]]],dtype=float)
        result=verify(mesh,shape,.015,max_cells=300)
        self.assertFalse(result['accepted'])

    def test_spline_pcurve_capsules_enclose_the_native_curve(self):
        poles=TColgp_Array1OfPnt2d(1,4)
        for i,p in enumerate([(0,0),(.2,1),(.8,-.5),(1,0)],1):poles.SetValue(i,gp_Pnt2d(*p))
        native=Geom2d_BezierCurve(poles);curve=SplineCurve2D(native,True)
        pieces=curve.segments(0,1,.001)
        self.assertGreater(len(pieces),1)
        for a,b,remainder in pieces:
            p,q=np.asarray(native.Value(a).Coord()),np.asarray(native.Value(b).Coord())
            for t in np.linspace(a,b,7):
                fraction=(t-a)/(b-a)
                actual=np.asarray(native.Value(float(t)).Coord())
                self.assertLessEqual(np.linalg.norm(actual-((1-fraction)*p+fraction*q)),remainder+1e-13)

    def test_rational_c0_pcurve_splits_knots_and_bounds_one_sided_derivatives(self):
        poles=TColgp_Array1OfPnt2d(1,5);weights=TColStd_Array1OfReal(1,5)
        knots=TColStd_Array1OfReal(1,3);multiplicities=TColStd_Array1OfInteger(1,3)
        for i,point in enumerate([(0,0),(.2,1),(.5,.2),(.7,-.5),(1,0)],1):
            poles.SetValue(i,gp_Pnt2d(*point));weights.SetValue(i,[1,.7,1.2,.8,1][i-1])
        for i,(value,multiplicity) in enumerate([(0,3),(.5,2),(1,3)],1):
            knots.SetValue(i,value);multiplicities.SetValue(i,multiplicity)
        native=Geom2d_BSplineCurve(poles,weights,knots,multiplicities,2,False)
        curve=SplineCurve2D(native);pieces=curve.segments(0,1,.001)
        self.assertTrue(any(b==.5 for a,b,error in pieces))
        self.assertTrue(any(a==.5 for a,b,error in pieces))
        for a,b,remainder in pieces:
            self.assertFalse(a<.5<b)
            bound=curve.second_bound(a,b)
            p,q=np.asarray(native.Value(a).Coord()),np.asarray(native.Value(b).Coord())
            for fraction in [.01,.2,.5,.8,.99]:
                t=a+(b-a)*fraction
                position=gp_Pnt2d();first=gp_Vec2d();second=gp_Vec2d()
                native.D2(t,position,first,second)
                self.assertLessEqual(second.Magnitude(),bound)
                chord=(1-fraction)*p+fraction*q
                self.assertLessEqual(np.linalg.norm(np.asarray(position.Coord())-chord),remainder+1e-13)

    def test_transformed_rational_surface_encloses_world_values_and_derivatives(self):
        shape=rational_face().located(cq.Location(cq.Vector(8,-4,3),cq.Vector(1,2,3),37))
        self.assertFalse(shape.wrapped.Location().IsIdentity())
        prepared=_Face(shape,.2);native=BRepAdaptor_Surface(shape.wrapped)
        rectangle=(.15,.35,.2,.45)
        bounds=prepared.spline.derivative_bounds(rectangle)
        for u in [.17,.25,.33]:
            for v in [.23,.32,.42]:
                point=gp_Pnt();du=gp_Vec();dv=gp_Vec();duu=gp_Vec();dvv=gp_Vec();duv=gp_Vec()
                native.D2(u,v,point,du,dv,duu,dvv,duv)
                for interval,coordinate in zip(prepared.evaluate((u,v)),point.Coord()):
                    self.assertLessEqual(interval.lo,coordinate);self.assertGreaterEqual(interval.hi,coordinate)
                for derivative,bound in zip([du,dv,duu,duv,dvv],bounds):
                    self.assertLessEqual(derivative.Magnitude(),bound)

    def test_helical_sweep_spline_faces_and_trims_have_bounded_success(self):
        shape=helical_sweep()
        points,indices=shape.tessellate(.04,.5)
        reference=np.asarray([[points[i].toTuple() for i in triangle] for triangle in indices])
        result=verify(reference,shape,.3,max_cells=5000)
        self.assertTrue(result["accepted"],result)
        for key in ["source_to_result_deviation","result_to_source_deviation"]:
            self.assertEqual(result["report"][key]["verification"],"bounded")
            self.assertLessEqual(result["report"][key]["upper_bound"],.3)

    def test_unknown_parametric_representation_still_fails_closed(self):
        shape=unsupported_extrusion()
        result=verify(triangles(shape),shape,.1)
        self.assertFalse(result['accepted'])
        self.assertIn('Surface',result['issues'][0]['explanation'])


if __name__=='__main__':unittest.main()
