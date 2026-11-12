"""Revision-pinned unsigned discrepancy feedback and conservative final checking.

Only compare is public reconstruction work here.  Mesh bounds and splines are
internal numerical oracles; no recognition/fitting/assembly pipeline is exposed.
"""
from __future__ import annotations

import hashlib
import copy
import heapq
import io
import math

import numpy as np
from mesh_reference import (ReferenceMesh, canonical_digest, connected_components, reference,
                            triangle_distances, triangle_ranges)


def _shape(value):
    import cadquery as cq
    if value is None:return None
    if isinstance(value,cq.Workplane):value=value.val()
    if isinstance(value,cq.Assembly):value=value.toCompound()
    if not isinstance(value,cq.Shape):value=cq.Shape.cast(value)
    return value


def geometry_digest(shape):
    shape=_shape(shape)
    if shape is None or shape.isNull():return hashlib.sha256(b"empty CAD boundary").hexdigest()
    isolated=shape.copy(mesh=False);stream=io.BytesIO()
    if not isolated.exportBrep(stream):raise ValueError("Could not fingerprint native CAD geometry")
    return hashlib.sha256(stream.getvalue()).hexdigest()


def _reference(context):
    if not isinstance(context,dict):raise ValueError("A reference context is required")
    vertices=np.asarray(context.get("vertices"),float);triangles=np.asarray(context.get("triangles"),dtype=np.int64)
    if vertices.ndim!=2 or vertices.shape[1]!=3 or not len(vertices) or not np.isfinite(vertices).all():raise ValueError("Reference vertices must be finite xyz coordinates")
    raw=np.asarray(context.get("triangles"))
    if raw.dtype.kind not in "iu" or triangles.ndim!=2 or triangles.shape[1]!=3 or not len(triangles) or not np.array_equal(raw,triangles) or triangles.min()<0 or triangles.max()>=len(vertices):raise ValueError("Reference triangles must have valid integer indices")
    delta=context.get("max_deviation")
    if isinstance(delta,bool) or not isinstance(delta,(float,int)) or not math.isfinite(delta) or delta<0:raise ValueError("Reference maximum deviation must be finite and nonnegative")
    if not isinstance(context.get("units"),str) or not context["units"] or not context.get("source_hash"):raise ValueError("Reference units and source hash are required")
    shared=reference(vertices,triangles)
    if shared.comparison is None:
        shared.comparison=_Source(vertices,triangles,shared.digest,shared=shared)
    return shared.comparison


class _Source:
    def __init__(self,vertices,triangles,digest,build_index=True,shared=None):
        shared=shared if shared is not None else ReferenceMesh(vertices,triangles,digest)
        self.vertices,self.triangles,self.digest=shared.vertices,shared.triangles,digest
        self.faces,self.centroids=shared.faces,shared.centroids
        cross=np.cross(self.faces[:,1]-self.faces[:,0],self.faces[:,2]-self.faces[:,0]);twice=np.linalg.norm(cross,axis=1)
        if not np.isfinite(twice).all():raise ValueError("Reference dynamic range exceeds numerical analysis")
        self.areas=twice/2;self.normals=np.divide(cross,twice[:,None],out=np.zeros_like(cross),where=twice[:,None]>0)
        self.areas.setflags(write=False);self.normals.setflags(write=False)
        self.low,self.high,self.span=shared.low,shared.high,max(shared.scale,1e-12)
        self.unique,_,self.welded=shared.welding;self.indexed=shared.indexed
        incidence=shared.incidence(self.areas)
        self.edges,self.adjacency=incidence.edges,incidence.connected
        self.components=connected_components(set(np.flatnonzero(self.areas>0)),self.adjacency)
        self._tree=[];self.root=self._build(np.arange(len(triangles))) if build_index else None
        self._audit=None

    def _build(self,indices):
        values=self.faces[indices];low=values.min(axis=(0,1));high=values.max(axis=(0,1));index=len(self._tree)
        self._tree.append(None)
        if len(indices)<=12:self._tree[index]=(low,high,None,None,indices)
        else:
            axis=int(np.argmax(np.ptp(self.centroids[indices],axis=0)));order=indices[np.argsort(self.centroids[indices,axis],kind="stable")];middle=len(order)//2
            left=self._build(order[:middle]);right=self._build(order[middle:]);self._tree[index]=(low,high,left,right,None)
        return index

    def closest(self,point):
        queue=[(0.,self.root)];best=math.inf;witness=None;triangle=None;bary=None
        while queue:
            lower,index=heapq.heappop(queue)
            if lower>best:continue
            low,high,left,right,indices=self._tree[index]
            if indices is not None:
                distances,points,weights=triangle_distances(point,self.faces[indices])
                local=int(np.argmin(distances))
                if distances[local]<best:best=float(distances[local]);witness=points[local];triangle=int(indices[local]);bary=weights[local]
            else:
                for child in (left,right):
                    a,b,*_=self._tree[child];delta=np.maximum(np.maximum(a-point,point-b),0);bound=float(delta@delta)
                    if bound<=best:heapq.heappush(queue,(bound,child))
        return math.sqrt(max(0,best)),witness,triangle,bary


def _scope(context,source,scope):
    if scope=="all":return np.arange(len(source.triangles)),True,{"source":"all","cad":"all"}
    if not isinstance(scope,dict):raise ValueError("Comparison scope is all or an explicit selection object")
    if "triangle_ids" in scope:ids=scope["triangle_ids"]
    elif "cad_face_refs" in scope and "region_ids" not in scope and "bounds" not in scope:ids=[]
    elif "region_ids" in scope:
        regions={r["id"]:r["triangle_ids"] for r in context.get("regions",[])}
        if any(r not in regions for r in scope["region_ids"]):raise ValueError("Unknown comparison region")
        ids=sorted({t for r in scope["region_ids"] for t in regions[r]})
    elif "bounds" in scope:
        bounds=scope["bounds"];low=_numbers(bounds["min"]);high=_numbers(bounds["max"])
        if np.any(high<low):raise ValueError("Comparison bounds must increase")
        ids=np.flatnonzero(np.all(source.faces.max(axis=1)>=low,axis=1)&np.all(source.faces.min(axis=1)<=high,axis=1)).tolist()
    else:raise ValueError("Unsupported comparison scope; supply triangle_ids, region_ids or bounds")
    if not isinstance(ids,(list,tuple,np.ndarray)) or any(isinstance(i,bool) or not isinstance(i,(int,np.integer)) or not 0<=i<len(source.triangles) for i in ids):raise ValueError("Comparison triangle IDs are invalid")
    return np.asarray(sorted(set(ids)),int),False,{"source_triangle_ids":sorted(set(ids)),"cad_face_refs":scope.get("cad_face_refs"),"source_selection_rule":"whole original triangles; a bounds predicate selects intersecting triangles without clipping","target_rule":"source points search the complete exposed CAD boundary; reverse CAD scope remains explicit"}


def _source_samples(source,ids,budget):
    if not len(ids):return []
    areas=source.areas[ids];total=float(areas.sum());count=min(budget,len(ids)*3)
    picks=ids[np.searchsorted(np.cumsum(areas),(np.arange(count)+.5)*total/count)] if total>0 else ids[np.linspace(0,len(ids)-1,count,dtype=int)]
    rows=[]
    for index,tid in enumerate(picks):
        # Interior barycentrics change deterministically within each triangle,
        # including centroids. They never substitute vertices for area evidence.
        bary=[1/3,1/3,1/3] if index%3==0 else [.6,.2,.2] if index%3==1 else [.2,.6,.2]
        rows.append({"triangle_id":int(tid),"barycentric":bary,"position":(np.asarray(bary)@source.faces[tid]).tolist(),"stratum":"area","area_weight":total/count})
    selected=set(int(t) for t in ids)
    for component in source.components[:max(1,budget//4)]:
        candidates=[t for t in component if t in selected]
        if candidates:
            tid=max(candidates,key=lambda t:source.areas[t]);rows.append({"triangle_id":tid,"barycentric":[1/3]*3,"position":source.centroids[tid].tolist(),"stratum":"component_guard","area_weight":0.})
    for tid in ids[source.areas[ids]==0][:budget//8]:
        for bary in ([1,0,0],[0,1,0],[0,0,1]):rows.append({"triangle_id":int(tid),"barycentric":bary,"position":(np.asarray(bary)@source.faces[tid]).tolist(),"stratum":"lower_dimensional","area_weight":0.})
    for index,row in enumerate(rows):row["id"]="mesh-sample-"+canonical_digest([source.digest,row["triangle_id"],row["barycentric"],row["stratum"]])[:20]
    return rows


def _nearest_cad(point,boundary,faces,refs):
    import cadquery as cq
    from OCP.BRepExtrema import BRepExtrema_DistShapeShape
    solver=BRepExtrema_DistShapeShape(cq.Vertex.makeVertex(*point).wrapped,boundary.wrapped)
    if not solver.IsDone() or not solver.NbSolution():raise RuntimeError("Native boundary distance did not complete")
    witness=solver.PointOnShape2(1);support=solver.SupportOnShape2(1);entity=None
    for i,face in enumerate(faces):
        if support.IsSame(face.wrapped):entity=refs[i];break
    return float(solver.Value()),list(witness.Coord()),entity


def _cad_samples(shape,refs,budget,span):
    from OCP.BRepMesh import BRepMesh_IncrementalMesh
    from OCP.BRep import BRep_Tool
    from OCP.TopLoc import TopLoc_Location
    from OCP.BRepAdaptor import BRepAdaptor_Surface
    from OCP.BRepClass import BRepClass_FaceClassifier
    from OCP.TopAbs import TopAbs_IN,TopAbs_ON
    from OCP.gp import gp_Pnt2d
    isolated=shape.copy(mesh=False);mesher=BRepMesh_IncrementalMesh(isolated.wrapped,max(span/180,.002),False,.45,True)
    if not mesher.IsDone():raise RuntimeError("Preview sampling triangulation failed")
    cells=[];faces=isolated.Faces()
    for fi,face in enumerate(faces):
        loc=TopLoc_Location();poly=BRep_Tool.Triangulation_s(face.wrapped,loc)
        if poly is None:continue
        transform=loc.Transformation();adaptor=BRepAdaptor_Surface(face.wrapped)
        for index in range(1,poly.NbTriangles()+1):
            node_ids=poly.Triangle(index).Get();points=np.asarray([poly.Node(i).Transformed(transform).Coord() for i in node_ids]);area=float(np.linalg.norm(np.cross(points[1]-points[0],points[2]-points[0]))/2)
            cells.append((fi,index,node_ids,points,area,poly,adaptor))
    if not cells:return [],{"complete":False,"reason":"No sampling cells"}
    areas=np.asarray([c[4] for c in cells]);total=float(areas.sum());count=min(budget,len(cells))
    picks=np.searchsorted(np.cumsum(areas),(np.arange(count)+.5)*total/count) if total>0 else np.arange(count)
    selected=[(int(i),total/count,"area") for i in picks]
    face_cells={}
    for i,c in enumerate(cells):face_cells.setdefault(c[0],[]).append(i)
    ordered=sorted(face_cells,key=lambda fi:-sum(cells[i][4] for i in face_cells[fi]))
    for fi in ordered[:max(1,budget//2)]:
        choices=face_cells[fi]
        selected.append((max(choices,key=lambda i:cells[i][4]),0.,"face_guard"))
    rows=[]
    for index,weight,stratum in selected:
        fi,triangle,node_ids,points,area,poly,adaptor=cells[index];face=faces[fi]
        point=points.mean(axis=0);uv=None
        if poly.HasUVNodes():
            uv=np.asarray([poly.UVNode(i).Coord() for i in node_ids]).mean(axis=0)
            classifier=BRepClass_FaceClassifier(face.wrapped,gp_Pnt2d(*uv),1e-9)
            if classifier.State() in (TopAbs_IN,TopAbs_ON):point=np.asarray(adaptor.Value(*uv).Coord())
            else:uv=None
        if uv is None:
            distance,witness,_=_nearest_cad(point,face,[face],[refs[fi]]);point=np.asarray(witness)
        rows.append({"id":"cad-sample-"+canonical_digest([refs[fi],triangle,stratum])[:20],"cad_entity_ref":refs[fi],"position":point.tolist(),"uv":uv.tolist() if uv is not None else None,"stratum":stratum,"area_weight":weight})
    return rows,{"complete":False,"method":"isolated acceleration triangulation chooses UV/trim-valid native surface samples; no meshing-error certificate","sampling_deflection":max(span/180,.002),"sampled_face_refs":sorted({r["cad_entity_ref"] for r in rows}),"face_count":len(faces)}


def _stats(samples,domain,target,units,coverage):
    finite=[s for s in samples if s.get("distance") is not None and math.isfinite(s["distance"])];weighted=[s for s in finite if s.get("area_weight",0)>0]
    quantiles=None;rms=None
    if weighted:
        values=np.asarray([s["distance"] for s in weighted]);weights=np.asarray([s["area_weight"] for s in weighted]);order=np.argsort(values);cdf=np.cumsum(weights[order])/sum(weights)
        rms=float(np.sqrt(np.average(values**2,weights=weights)));quantiles={str(q):float(values[order[min(np.searchsorted(cdf,q),len(order)-1)]]) for q in [.5,.9,.95,.99]}
    return {
        "domain_ref":domain,"target_ref":target,
        "sampled_max":max((s["distance"] for s in finite),default=None),
        "area_weighted_rms":rms,"area_weighted_quantiles":quantiles,
        "lower_bound":None,"upper_bound":None,"guarantee":"sampled" if finite else "unavailable",
        "units":units,"samples":samples,
        "witness_refs":[s["id"] for s in sorted(finite,key=lambda r:-r["distance"])[:16]],
        "coverage":coverage,
        "numeric_policy":"ordinary floating/native closest distances are estimates, not rigorous lower witnesses",
        "unavailable_reason":None if finite else "No nonempty opposite boundary or no completed samples"}


def _residual_regions(source,samples,threshold,model_ref):
    by_triangle={}
    for sample in samples:
        if sample.get("distance") is not None and sample["distance"]>threshold:by_triangle.setdefault(sample["triangle_id"],[]).append(sample)
    rows=[]
    for group in connected_components(set(by_triangle),source.adjacency):
        evidence=[s for t in group for s in by_triangle[t]]
        rows.append({
            "id":"residual-"+canonical_digest([source.digest,model_ref,group])[:20],"direction":"mesh_to_cad",
            "triangle_ids":group,"sample_ids":[s["id"] for s in evidence],
            "minimum_distance":min(s["distance"] for s in evidence),
            "maximum_distance":max(s["distance"] for s in evidence),
            "area_estimate":sum(s["area_weight"] for s in evidence),
            "location":max(evidence,key=lambda s:s["distance"])["position"],
            "connectivity":"original exact-incidence adjacency among sampled failing triangles",
            "complete":False,"unprocessed_complement":True,"guarantee":"sampled"})
    return sorted(rows,key=lambda r:-r["maximum_distance"])


def _native_checks(shape,final=False,face_budget=2048):
    if shape is None or shape.isNull():return [{"kind":"required_body","status":"fail","reason":"The CAD revision is empty"}]
    from OCP.BRepCheck import BRepCheck_Analyzer
    from OCP.BRep import BRep_Tool
    solids=shape.Solids();shells=shape.Shells();faces=shape.Faces()
    only_solids=bool(solids) and sum(len(s.Faces()) for s in solids)==len(faces)
    checks=[{"kind":"required_body","status":"pass" if only_solids else "fail","solid_count":len(solids),"reason":None if only_solids else "The target contains no solid or includes standalone construction surfaces"},
            {"kind":"native_brep_validity","status":"pass" if BRepCheck_Analyzer(shape.wrapped,True,False,True).IsValid() else "fail","method":"OCCT exact-method curve-on-surface and native topology checks; not a Hausdorff certificate"},
            {"kind":"closed_positive_solids","status":"pass" if solids and shells and all(BRep_Tool.IsClosed_s(s.wrapped) for s in shells) and all(math.isfinite(s.Volume()) and s.Volume()>0 for s in solids) else "fail"}]
    if final and solids and len(faces)>face_budget:
        checks.append({"kind":"native_self_interference","status":"inconclusive","reason":"Native self-interference face budget exceeded","face_budget":face_budget})
    elif final and solids:
        from OCP.BOPAlgo import BOPAlgo_CheckerSI
        checker=BOPAlgo_CheckerSI();checker.SetNonDestructive(True);checker.SetLevelOfCheck(9);checker.AddArgument(shape.wrapped);checker.Perform()
        complete=not checker.HasErrors();count=int(checker.DS().Interferences().Extent())
        checks.append({"kind":"native_self_interference","status":"inconclusive" if not complete else "pass" if count==0 else "fail","interference_count":count,"method":"OCCT BOPAlgo_CheckerSI level9 non-destructive"})
    return checks


def _result_requirement(requirement,status,reason=None,**values):
    identity=requirement.get("id")
    if not identity:
        try:identity="requirement-"+canonical_digest(requirement)[:16]
        except (ValueError,TypeError):identity="invalid-requirement-"+hashlib.sha256(repr(requirement).encode()).hexdigest()[:16]
    return {"id":identity,"kind":requirement.get("kind"),"mandatory":requirement.get("mandatory",True),"status":status,"reason":reason,**values}


def _numbers(values,count=3):
    a=np.asarray(values,float)
    if a.shape!=(count,) or not np.isfinite(a).all():raise ValueError("Expected finite coordinates")
    return a


def _cylinder_requirement(shape,requirement):
    import cadquery as cq
    from OCP.BRepAdaptor import BRepAdaptor_Surface
    from OCP.BRepTools import BRepTools
    from OCP.GeomAbs import GeomAbs_Cylinder,GeomAbs_Line
    from OCP.BRepTools import BRepTools_WireExplorer
    from OCP.BRepAdaptor import BRepAdaptor_Curve2d
    origin=_numbers(requirement.get("origin",[0,0,0]));axis=_numbers(requirement["axis"]);scale=float(np.max(np.abs(axis)))
    if scale==0:raise ValueError("Feature axis must be nonzero")
    axis=axis/scale;axis/=np.linalg.norm(axis);radius=float(requirement["radius"]);tolerance=float(requirement.get("tolerance",1e-6))
    if not math.isfinite(radius) or radius<=0 or not math.isfinite(tolerance) or tolerance<=0:raise ValueError("Feature radius/tolerance must be positive")
    bore=requirement["kind"] in {"bore","through_bore"};matches=[];incomplete=[]
    desired=requirement.get("axial_range")
    if desired is not None:
        desired=_numbers(desired,2)
        if desired[1]<=desired[0]:raise ValueError("Feature axial range must increase")
    for index,face in enumerate(shape.Faces()):
        adaptor=BRepAdaptor_Surface(face.wrapped)
        if adaptor.GetType()!=GeomAbs_Cylinder:continue
        cylinder=adaptor.Cylinder();direction=np.asarray(cylinder.Axis().Direction().Coord());point=np.asarray(cylinder.Location().Coord())
        if abs(cylinder.Radius()-radius)>tolerance or np.linalg.norm(np.cross(direction,axis))>max(1e-8,tolerance/max(radius,1)) or np.linalg.norm(np.cross(point-origin,axis))>tolerance:continue
        u0,u1,v0,v1=BRepTools.UVBounds_s(face.wrapped);midpoint=np.asarray(adaptor.Value((u0+u1)/2,(v0+v1)/2).Coord());radial=midpoint-point-direction*np.dot(midpoint-point,direction)
        sign=float(np.dot(face.normalAt(cq.Vector(*midpoint)).toTuple(),radial))
        if bore and sign>=0:continue
        interval=sorted([float((point+direction*v-origin)@axis) for v in (v0,v1)])
        regular=len(face.Wires())==1 and abs((u1-u0)-2*math.pi)<=max(1e-7,tolerance/max(radius,1))
        for wire in face.Wires():
            explorer=BRepTools_WireExplorer(wire.wrapped,face.wrapped)
            while explorer.More():
                curve=BRepAdaptor_Curve2d(explorer.Current(),face.wrapped)
                if curve.GetType()!=GeomAbs_Line:regular=False
                else:
                    d=curve.Line().Direction();regular=regular and min(abs(d.X()),abs(d.Y()))<1e-8
                explorer.Next()
        if not regular:incomplete.append(index+1);continue
        matches.append({"face_index":index+1,"axial_range":interval,"radius":cylinder.Radius(),"inward":sign<0})
    if not matches:
        return _result_requirement(requirement,"inconclusive" if incomplete else "fail","Matching exposed cylindrical support has unsupported trims" if incomplete else "No compatible exposed inward bore wall" if bore else "No compatible exposed cylindrical wall",candidate_faces=incomplete)
    intervals=sorted(m["axial_range"] for m in matches);merged=[]
    for a,b in intervals:
        if merged and a<=merged[-1][1]+tolerance:merged[-1][1]=max(merged[-1][1],b)
        else:merged.append([a,b])
    if desired is not None and not any(a<=desired[0]+tolerance and b>=desired[1]-tolerance for a,b in merged):return _result_requirement(requirement,"fail","Exposed cylindrical wall does not cover the required axial extent",observed_intervals=merged)
    if requirement.get("through",requirement["kind"]=="through_bore"):
        bounds=shape.BoundingBox();corners=np.asarray([[x,y,z] for x in (bounds.xmin,bounds.xmax) for y in (bounds.ymin,bounds.ymax) for z in (bounds.zmin,bounds.zmax)])
        axial=(corners-origin)@axis;span=max(float(np.ptp(axial)),radius,1);low=float(axial.min())-span;high=float(axial.max())+span
        edge=cq.Edge.makeLine(cq.Vector(*(origin+axis*low)),cq.Vector(*(origin+axis*high)))
        from OCP.BRepAlgoAPI import BRepAlgoAPI_Common
        common=BRepAlgoAPI_Common(edge.wrapped,shape.wrapped);common.SetNonDestructive(True);common.Build()
        if not common.IsDone():return _result_requirement(requirement,"inconclusive","Native line/material intersection did not complete")
        material=cq.Shape.cast(common.Shape())
        if material.Edges() or material.Vertices():return _result_requirement(requirement,"fail","Material obstructs the full bore centerline",observed_intervals=merged)
    return _result_requirement(requirement,"pass",method="actual exposed analytic cylinder/regular trim checks and native through-path intersection",matched_faces=matches)


def check_requirements(context,target,requirements):
    """Check immutable predicates against the actual target, never fit metadata."""
    if not isinstance(requirements,list):raise ValueError("Requirements must be a list")
    shape=_shape(target.get("shape") if isinstance(target,dict) else target);results=[]
    for requirement in requirements:
        if isinstance(requirement,str):
            definitions=context.get("policy",{}).get("requirement_definitions",{})
            if isinstance(definitions,list):definitions={r.get("id"):r for r in definitions if isinstance(r,dict)}
            if not isinstance(definitions,dict) or requirement not in definitions:
                results.append({"id":requirement,"kind":"reference","mandatory":True,"status":"inconclusive","reason":"Unresolved requirement reference"});continue
            requirement={**definitions[requirement],"id":requirement}
        if not isinstance(requirement,dict):raise ValueError("A requirement must be an object or stable ID")
        kind=requirement.get("kind")
        if shape is None or shape.isNull() or not shape.Solids():results.append(_result_requirement(requirement,"fail","Required solid is absent"));continue
        try:
            if kind=="body_count":
                count=requirement.get("count",requirement.get("value"))
                if type(count) is not int or count<1:raise ValueError("Body count must be a positive integer")
                actual=len(shape.Solids());results.append(_result_requirement(requirement,"pass" if actual==count else "fail",observed=actual,expected=count))
            elif kind=="volume":
                value=sum(s.Volume() for s in shape.Solids());low=requirement.get("minimum",-math.inf);high=requirement.get("maximum",math.inf);tol=float(requirement.get("tolerance",1e-8))
                if any(isinstance(requirement[k],bool) or not isinstance(requirement[k],(int,float)) or not math.isfinite(requirement[k]) for k in ("minimum","maximum") if k in requirement) or not math.isfinite(tol) or tol<=0 or low>high:raise ValueError("Volume limits and tolerance must be finite, positive-tolerance ordered numbers")
                status="fail" if value<low-tol or value>high+tol else "inconclusive" if abs(value-low)<=tol or abs(value-high)<=tol else "pass"
                results.append(_result_requirement(requirement,status,observed=value,units=context["units"]+"^3",method="OCCT native volume integrals with declared tolerance",tolerance=tol))
            elif kind=="bounds":
                low=_numbers(requirement["minimum"]);high=_numbers(requirement["maximum"]);b=shape.BoundingBox();actual_low=np.asarray([b.xmin,b.ymin,b.zmin]);actual_high=np.asarray([b.xmax,b.ymax,b.zmax]);tol=float(requirement.get("tolerance",1e-6))
                if np.any(high<low) or not math.isfinite(tol) or tol<=0:raise ValueError("Bounds and tolerance must be ordered finite values with positive tolerance")
                status="pass" if np.all(actual_low>=low-tol) and np.all(actual_high<=high+tol) else "fail"
                results.append(_result_requirement(requirement,status,observed={"minimum":actual_low.tolist(),"maximum":actual_high.tolist()},method="native analytic bounding box containment",tolerance=tol))
            elif kind in {"cylinder","bore","through_bore"}:results.append(_cylinder_requirement(shape,requirement))
            else:results.append(_result_requirement(requirement,"inconclusive","Unsupported realized-geometry requirement predicate"))
        except (ValueError,KeyError,TypeError) as error:results.append(_result_requirement(requirement,"inconclusive",str(error)))
        except Exception as error:results.append(_result_requirement(requirement,"inconclusive",f"Native requirement check did not complete: {error}"))
    return results


def audit_body(shape,*,face_budget=2048):
    """Current-body gates only; unfinished reconstruction never blocks edits."""
    if type(face_budget) is not int or not 1<=face_budget<=20000:raise ValueError("Native face budget must be from 1 to 20,000")
    shape=_shape(shape)
    try:
        checks=_native_checks(shape.copy(mesh=False) if shape is not None else None,True,face_budget)
        status="fail" if any(c["status"]=="fail" for c in checks) else "inconclusive" if any(c["status"]!="pass" for c in checks) else "pass"
        return {"status":status,"checks":checks,"native_geometry_digest":geometry_digest(shape),"scope":"current body validity only; reference agreement and completion obligations are separate","face_budget":face_budget}
    except Exception as error:return {"status":"inconclusive","checks":[{"kind":"native_body_audit","status":"inconclusive","reason":str(error)}],"scope":"current body validity only"}


def _settings(context):
    outer=context.get("policy",{})
    values=outer.get("compare_policy",context.get("compare_policy",{}))
    if not isinstance(values,dict):raise ValueError("compare_policy must be an object")
    if "compare_policy" in outer and "compare_policy" in context and values!=context["compare_policy"]:raise ValueError("Inconsistent comparison policy dependencies")
    allowed={"preview_samples","final_max_cells","native_si_face_budget","sharp_feature_degrees","feature_pair_budget","source_audit","require_material_difference"}
    if set(values)-allowed:raise ValueError("Unsupported comparison settings: "+", ".join(sorted(set(values)-allowed)))
    ranges={"preview_samples":(16,2048),"final_max_cells":(1,2_000_000),"native_si_face_budget":(1,20000),"feature_pair_budget":(1,2_000_000)}
    for key,(low,high) in ranges.items():
        if key in values and (type(values[key]) is not int or not low<=values[key]<=high):raise ValueError(f"{key} must be an integer from {low} to {high}")
    if "sharp_feature_degrees" in values:
        v=values["sharp_feature_degrees"]
        if isinstance(v,bool) or not isinstance(v,(int,float)) or not math.isfinite(v) or not 0<v<180:raise ValueError("sharp_feature_degrees must be between 0 and 180")
    if "require_material_difference" in values and type(values["require_material_difference"]) is not bool:raise ValueError("require_material_difference must be boolean")
    audit=values.get("source_audit",{})
    if not isinstance(audit,dict) or set(audit)-{"max_node_pairs","max_candidate_pairs","max_exact_pairs","max_issues"}:raise ValueError("Unsupported source-audit settings")
    for key,value in audit.items():
        if type(value) is not int or not 1<=value<=10_000_000:raise ValueError("Source-audit budgets must be positive bounded integers")
    return values


def _source_audit(source,policy):
    from mesh_intersections import audit_self_intersections
    budgets=policy.get("source_audit",{})
    allowed={"max_node_pairs","max_candidate_pairs","max_exact_pairs","max_issues"}
    options={k:v for k,v in budgets.items() if k in allowed}
    key=canonical_digest(options)
    if source._audit is not None and source._audit[0]==key:return source._audit[1]
    audit=audit_self_intersections(source.unique,source.indexed,**options)
    closed=bool(source.components) and all(len(uses)==2 for uses in source.edges.values())
    oriented=closed and all(uses[0][1]!=uses[1][1] for uses in source.edges.values())
    duplicate=len({tuple(sorted(t)) for t in source.indexed[source.areas>0]})!=int(np.count_nonzero(source.areas))
    links={}
    for (a,b),uses in source.edges.items():
        for vertex in (a,b):
            local=links.setdefault(vertex,{})
            for tid,_ in uses:local.setdefault(tid,set()).update(other for other,_ in uses if other!=tid)
    nonmanifold_vertices=[]
    for vertex,local in links.items():
        if any(len(neighbors)!=2 for neighbors in local.values()) or len(connected_components(set(local),local))!=1:nonmanifold_vertices.append(vertex)
    euler=[];component_bounds=[]
    for group in source.components:
        faces=source.indexed[group];edges={tuple(sorted((int(a),int(b)))) for tri in faces for a,b in zip(tri,np.roll(tri,-1))}
        euler.append(int(len(np.unique(faces))-len(edges)+len(group)))
        xyz=source.faces[group];component_bounds.append((xyz.min(axis=(0,1)),xyz.max(axis=(0,1))))
    disjoint_boxes=all(np.any(a[1]<b[0]) or np.any(b[1]<a[0]) for i,a in enumerate(component_bounds) for b in component_bounds[i+1:])
    result={"intersection_audit":audit,"closed":closed,"orientation_consistent":oriented,"duplicate_faces":duplicate,"nonmanifold_vertex_ids":nonmanifold_vertices,"component_count":len(source.components),"euler_characteristics":sorted(euler),"component_bounds_disjoint":disjoint_boxes,"degenerate_primitive_count":int(np.count_nonzero(source.areas==0)),"reference_unchanged":True}
    source._audit=(key,result);return result


def _original_analysis(context,source):
    """Audit incidence/embedding before rounded physical unit conversion."""
    original=np.asarray(context.get("original_vertices",source.vertices),float)
    if original.shape!=source.vertices.shape or not np.isfinite(original).all():raise ValueError("Original reference coordinates are unavailable or inconsistent")
    if np.array_equal(original,source.vertices):return source,source,True
    key=hashlib.sha256(original.tobytes()+source.triangles.tobytes()).hexdigest()
    prior=getattr(source,"_original_analysis",None)
    if prior is None or prior.digest!=key:
        prior=_Source(original,source.triangles,key,build_index=False);source._original_analysis=prior
    _,representatives=np.unique(original,axis=0,return_index=True)
    working=copy.copy(prior)
    working.vertices=source.vertices;working.faces=source.faces;working.unique=source.vertices[representatives];working.span=source.span
    # Incidence cannot be inferred after a conversion collapses distinct source
    # positions. Keep original predicates and withhold resolved feature semantics.
    stable=len(working.unique)==len(source.unique) and np.array_equal(prior.areas>0,source.areas>0)
    return prior,working,stable


def _native_euler(shape):
    from OCP.BRep import BRep_Tool
    return sorted(len(shell.Vertices())-sum(not BRep_Tool.Degenerated_s(e.wrapped) for e in shell.Edges())+sum(2-len(f.Wires()) for f in shell.Faces()) for shell in shape.Shells())


def _protected_checks(source,shape,context):
    """Observed high-dihedral chains are a separate mandatory feature baseline."""
    import cadquery as cq
    from OCP.TopExp import TopExp
    from OCP.TopAbs import TopAbs_EDGE,TopAbs_FACE
    from OCP.TopTools import TopTools_IndexedDataMapOfShapeListOfShape
    from OCP.TopoDS import TopoDS
    from OCP.BRep import BRep_Tool
    policy=_settings(context);angle=math.radians(float(policy.get("sharp_feature_degrees",30)))
    if not 0<angle<math.pi:raise ValueError("Sharp feature threshold must be between 0 and 180 degrees")
    protected=[]
    for edge,uses in source.edges.items():
        if len(uses)!=2:continue
        ids=[u[0] for u in uses];normals=source.normals[ids]
        if math.acos(float(np.clip(normals[0]@normals[1],-1,1)))>=angle:protected.append((edge,ids,normals))
    native=[];mapping=TopTools_IndexedDataMapOfShapeListOfShape()
    TopExp.MapShapesAndAncestors_s(shape.wrapped,TopAbs_EDGE,TopAbs_FACE,mapping)
    for index in range(1,mapping.Extent()+1):
        edge=cq.Edge(TopoDS.Edge(mapping.FindKey(index)))
        if BRep_Tool.Degenerated_s(edge.wrapped):continue
        faces=[]
        for native_face in mapping.FindFromIndex(index):
            face=cq.Face(TopoDS.Face(native_face))
            if not any(face.isSame(other) for other in faces):faces.append(face)
        if len(faces)!=2:continue
        point=edge.positionAt(.5);normals=[np.asarray(f.normalAt(point).toTuple()) for f in faces]
        if math.acos(float(np.clip(normals[0]@normals[1],-1,1)))>=angle:native.append((edge,faces))
    max_pairs=int(policy.get("feature_pair_budget",1_000_000))
    if len(protected)*max(len(native),1)>max_pairs:return {"kind":"observed_sharp_features","status":"inconclusive","reason":"Protected-feature matching budget exhausted","source_edge_count":len(protected),"native_edge_count":len(native)}
    signs=np.ones(len(source.triangles))
    for group in source.components:
        values=source.faces[group];shifted=values-values.mean(axis=(0,1))
        terms=np.einsum("ij,ij->i",shifted[:,0],np.cross(shifted[:,1],shifted[:,2]));v=math.fsum(float(t) for t in terms)
        uncertainty=64*np.finfo(float).eps*float(np.sum(np.abs(terms)))
        if abs(v)<=uncertainty:return {"kind":"observed_sharp_features","status":"inconclusive","reason":"Outward source orientation is numerically unresolved"}
        signs[group]=1 if v>=0 else -1
    failed=[];source_segments=[];matches=[];native_segments=[]
    for edge,faces in native:
        nodes=[tuple(v.toTuple()) for v in edge.Vertices()]
        native_segments.append(nodes or [tuple(edge.startPoint().toTuple()),tuple(edge.endPoint().toTuple())])
    for vertices,triangle_ids,normals in protected:
        points=source.unique[list(vertices)];source_segments.append([tuple(p) for p in points]);midpoint=points.mean(axis=0)
        tolerance=max(source.span*1e-8,min(float(context["max_deviation"]),.05*float(np.linalg.norm(points[1]-points[0]))))
        acceptable=set()
        for index,(edge,faces) in enumerate(native):
            if max(edge.distance(cq.Vertex.makeVertex(*p)) for p in points)>tolerance:continue
            actual=[np.asarray(f.normalAt(cq.Vector(*midpoint)).toTuple()) for f in faces];expected=normals*signs[triangle_ids,None]
            if max(min(float(expected[0]@actual[0]),float(expected[1]@actual[1])),min(float(expected[0]@actual[1]),float(expected[1]@actual[0])))<math.cos(math.pi/8):continue
            acceptable.add(index)
        matches.append(acceptable)
        if not acceptable:failed.append({"source_edge_vertices":list(vertices),"triangle_ids":triangle_ids,"location":midpoint.tolist()})
    def components(segments):
        adjacency=[set() for _ in segments];locations={}
        for index,points in enumerate(segments):
            for point in points:locations.setdefault(point,[]).append(index)
        for uses in locations.values():
            for index in uses:adjacency[index].update(uses)
        return connected_components(set(range(len(segments))),adjacency)
    source_groups=components(source_segments);native_groups=components(native_segments)
    choices=[{i for i,g in enumerate(native_groups) if all(matches[e].intersection(g) for e in group)} for group in source_groups]
    owners={};matched=True
    for current in range(len(choices)):
        queue=[current];parents={current:None};visited=set();found=None
        while queue and found is None:
            node=queue.pop(0)
            for target in sorted(choices[node]-visited):
                visited.add(target)
                if target not in owners:found=(node,target);break
                other=owners[target]
                if other not in parents:parents[other]=(node,target);queue.append(other)
        if found is None:matched=False;break
        node,target=found
        while True:
            owners[target]=node
            if parents[node] is None:break
            node,target=parents[node]
    passed=not failed and matched and len(source_groups)==len(native_groups)
    return {
        "kind":"observed_sharp_features","status":"pass" if passed else "fail",
        "source_edge_count":len(protected),"native_edge_count":len(native),
        "source_chain_components":len(source_groups),"native_chain_components":len(native_groups),
        "unmatched_features":failed,"threshold_degrees":math.degrees(angle),
        "scope":"observed high-dihedral source features; source tessellation intent is not inferred",
        "method":"source endpoints, oriented incident normals and one-to-one sharp-chain correspondence"}


def _representation(context,target,shape):
    record=target.get("representation",{})
    if record.get("status") in {"faceted","triangle_wrapping","rejected"}:return {"kind":"reconstructed_representation","status":"fail","reason":"Faceted source wrapping is not a reconstructed CAD deliverable"}
    if record.get("source_hash") not in (None,context["source_hash"]):return {"kind":"reconstructed_representation","status":"inconclusive","reason":"Representation provenance belongs to a different source"}
    method=record.get("method")
    if record.get("status")=="reconstructed_brep" and method=="typed_cad_construction":
        operations=record.get("operations",[])
        forbidden={"triangle_mesh","mesh_to_brep","per_triangle_faces","faceted_import","triangle_spline_wrapping"}
        if any(isinstance(op,dict) and (op.get("kind") in forbidden or op.get("operation") in forbidden or op.get("per_triangle") is True) for op in operations):return {"kind":"reconstructed_representation","status":"fail","reason":"Construction provenance repeats source triangles"}
        return {"kind":"reconstructed_representation","status":"pass","method":"host typed compact CAD construction provenance","operations":operations}
    if record.get("status")=="reconstructed_brep" and method=="authored_program":
        import ast
        try:
            tree=ast.parse(target.get("script", ""));calls=[]
            for node in ast.walk(tree):
                if isinstance(node,ast.Call):
                    def name(value):return name(value.value)+"."+value.attr if isinstance(value,ast.Attribute) else value.id if isinstance(value,ast.Name) else ""
                    calls.append(name(node.func))
            dangerous={"makeFromWires","makePolygon","BRepBuilderAPI_MakeFace","Add","Read_s","importStep","importBrep"}
            wrapping=any(isinstance(n,(ast.For,ast.While,ast.ListComp)) for n in ast.walk(tree)) and any(c.split('.')[-1] in dangerous for c in calls)
            if wrapping:return {"kind":"reconstructed_representation","status":"inconclusive","reason":"Looped low-level surface construction needs explicit regional provenance; no automatic triangle-wrap approval"}
            known={"box","cylinder","sphere","cone","torus","extrude","revolve","loft","sweep","hole","cut","union","intersect","fillet","chamfer","makeBox","makeCylinder","makeSphere","makeCone","makeTorus"}
            if calls and any(c.split('.')[-1] in known for c in calls) and not any(c.split('.')[-1] in dangerous for c in calls):return {"kind":"reconstructed_representation","status":"pass","method":"authored compact primitive/profile program audit","source_hash":context["source_hash"]}
        except (SyntaxError,ValueError):pass
    return {"kind":"reconstructed_representation","status":"inconclusive","reason":"Reconstructed regional construction provenance is unavailable or unsupported"}


def _requirements(context,target,key):
    result=[];seen=set()
    for values in (context.get("policy",{}).get(key,[]),target.get("state",{}).get(key,[]),target.get(key,[])):
        if not isinstance(values,list):raise ValueError(key+" must be a list")
        for value in values:
            identity=value if isinstance(value,str) else value.get("id") or canonical_digest(value)
            if identity not in seen:result.append(value);seen.add(identity)
    return result


def _circular_strip_check(context,source,shape):
    """Do not approve replayed circular tessellation strips as compact CAD.

    Co-circular source contours do not prove original intent. A polygonal result
    in this ambiguous case remains inconclusive, rather than a false accusation
    that every many-sided mechanical profile is a faceted reconstruction.
    """
    tolerance=max(source.span*3e-6,1e-10);supports=[];seen=set();directions={}
    for normal,area in zip(source.normals,source.areas):
        if not area:continue
        normal=normal if normal[np.argmax(np.abs(normal))]>=0 else -normal
        key=tuple(np.round(normal,3))
        if key not in directions:directions[key]=[0.,np.zeros(3)]
        directions[key][0]+=float(area);directions[key][1]+=normal*area
    axes=[value[1]/np.linalg.norm(value[1]) for value in sorted(directions.values(),key=lambda value:-value[0])[:12]]
    for axis in axes:
        signature=tuple(np.round(axis,6))
        if signature in seen:continue
        seen.add(signature);axial=source.unique@axis;low,high=float(axial.min()),float(axial.max())
        if high-low<=tolerance:continue
        levels=source.faces@axis;cap=(np.max(np.abs(levels-low),axis=1)<=tolerance)|(np.max(np.abs(levels-high),axis=1)<=tolerance)
        side=(~cap)&(source.areas>0)
        if not np.any(side) or np.max(np.abs(source.normals[side]@axis))>1e-4:continue
        rim={}
        for edge,uses in source.edges.items():
            if len(uses)==2 and bool(cap[uses[0][0]])!=bool(cap[uses[1][0]]) and max(abs(axial[v]-low) for v in edge)<=tolerance:
                for a,b in (edge,edge[::-1]):rim.setdefault(a,set()).add(b)
        remaining=set(rim)
        while remaining:
            first=min(remaining);remaining.remove(first);queue=[first];group=[first]
            while queue:
                current=queue.pop()
                for neighbor in rim[current]&remaining:remaining.remove(neighbor);queue.append(neighbor);group.append(neighbor)
            if len(group)<8 or any(len(rim[v])!=2 for v in group):continue
            points=source.unique[group];origin=points.mean(axis=0);basis=np.eye(3)[int(np.argmin(np.abs(axis)))];x=basis-axis*float(axis@basis);x/=np.linalg.norm(x);y=np.cross(axis,x)
            xy=np.column_stack(((points-origin)@x,(points-origin)@y));matrix=np.column_stack((2*xy,np.ones(len(xy))))
            fitted,_,rank,_=np.linalg.lstsq(matrix,np.sum(xy*xy,axis=1),rcond=None)
            radius2=float(fitted[2]+fitted[:2]@fitted[:2])
            if rank<3 or radius2<=0:continue
            radius=math.sqrt(radius2);center=origin+x*fitted[0]+y*fitted[1]
            if np.max(np.abs(np.linalg.norm(xy-fitted[:2],axis=1)-radius))>tolerance:continue
            strips=[]
            for index,face in enumerate(shape.Faces()):
                if face.geomType()!="PLANE":continue
                vertices=np.asarray([v.toTuple() for v in face.Vertices()])
                if len(vertices)<3:continue
                offset=vertices-center;z=offset@axis
                if np.ptp(z)<=tolerance or min(z)<-tolerance or max(z)>high-low+tolerance:continue
                radial=np.linalg.norm(offset-z[:,None]*axis,axis=1)
                if np.max(np.abs(radial-radius))<=tolerance:strips.append(index+1)
            if len(strips)>=3:supports.append({"axis":axis.tolist(),"circle_center":center.tolist(),"radius":radius,"source_rim_vertex_count":len(group),"candidate_planar_strip_faces":strips})
    return {"kind":"circular_tessellation_replay","status":"inconclusive" if supports else "pass","suspect_supports":supports,"reason":"Co-circular source rims are replayed as many planar axial strips; independent polygonal-feature intent is required" if supports else None,"method":"source rim incidence/circle evidence plus actual exposed planar strip geometry; face count alone is not used"}


def _representation_strict(context,target,shape):
    result=_representation(context,target,shape)
    if target.get("representation",{}).get("method")=="authored_program" and result["status"]=="pass":
        import ast
        tree=ast.parse(target.get("script",""))
        low_level={"makePlane","makeFace","makeShell","makeSolid","makeFromWires","makePolygon","Face","Solid","Shell","Compound","BRep_Builder","BRepBuilderAPI_MakeFace","add","Add"}
        called=[]
        for node in ast.walk(tree):
            if isinstance(node,ast.Call):called.append(node.func.attr if isinstance(node.func,ast.Attribute) else node.func.id if isinstance(node.func,ast.Name) else "")
        if any(name in low_level for name in called):return {"kind":"reconstructed_representation","status":"inconclusive","reason":"Low-level authored face construction needs explicit meaningful regional provenance"}
        for node in ast.walk(tree):
            if isinstance(node,ast.ImportFrom) and (node.module or "").startswith("OCP"):
                return {"kind":"reconstructed_representation","status":"inconclusive","reason":"Direct native authored construction requires regional provenance audit"}
    return result


def compare(context,target,scope="all",quality="preview"):
    if quality not in {"preview","final"}:raise ValueError("Comparison quality must be preview or final")
    settings=_settings(context);source=_reference(context);target=dict(target) if isinstance(target,dict) else {"shape":target}
    shape=_shape(target.get("shape"));model_ref=target.get("id",target.get("model_ref","unidentified-native-result"));native_digest=geometry_digest(shape)
    if target.get("units",context["units"])!=context["units"]:raise ValueError("CAD target and reference coordinate units differ")
    geometry_hash=target.get("geometry_hash",native_digest);context_revision=context.get("context_revision",context.get("revision",context.get("id")))
    ids,whole,domains=_scope(context,source,scope);units=context["units"];policy=context.get("policy",{})
    budget=settings.get("preview_samples",256)
    if type(budget) is not int or not 16<=budget<=2048:raise ValueError("preview_samples must be between 16 and 2048")
    source_rows=_source_samples(source,ids,budget);cad_rows=[];limitations=[];methods=["deterministic original-triangle interior sampling","native bounded-boundary minimum-distance estimates","original-triangle BVH closest-point estimates"]
    faces=shape.Faces() if shape is not None and not shape.isNull() else []
    refs=target.get("cad_face_refs") or [f"{model_ref}/face/{i+1}" for i in range(len(faces))]
    if len(refs)!=len(faces):raise ValueError("CAD face reference count does not match exact target faces")
    selected_cad=domains.get("cad_face_refs")
    if selected_cad is not None and (not isinstance(selected_cad,list) or not all(isinstance(r,str) and r in refs for r in selected_cad)):raise ValueError("Unknown or stale revision-scoped CAD face reference")
    if faces:
        import cadquery as cq
        boundary=cq.Compound.makeCompound(faces)
        for row in source_rows:
            try:distance,witness,entity=_nearest_cad(row["position"],boundary,faces,refs);row.update(distance=distance,nearest_position=witness,nearest_cad_entity_ref=entity)
            except Exception as error:row.update(distance=None,unavailable_reason=str(error))
        try:
            cad_rows,cad_coverage=_cad_samples(shape,refs,budget,source.span)
            explicit=domains.get("cad_face_refs")
            if not whole:
                if explicit is None:cad_rows=[];cad_coverage.update(reason="A mesh-only local scope does not define reverse CAD coverage",sampled_face_refs=[])
                else:cad_rows=[r for r in cad_rows if r["cad_entity_ref"] in set(explicit)]
            for row in cad_rows:
                distance,witness,triangle,bary=source.closest(np.asarray(row["position"]));row.update(distance=distance,nearest_position=witness.tolist(),triangle_id=triangle,nearest_barycentric=bary.tolist())
        except Exception as error:cad_coverage={"complete":False,"reason":str(error)};limitations.append("CAD sampling incomplete: "+str(error))
    else:
        for row in source_rows:row.update(distance=None,unavailable_reason="The current CAD body is empty")
        cad_coverage={"complete":False,"reason":"No exposed CAD boundary"}
    sampled=sorted({r["triangle_id"] for r in source_rows if r.get("distance") is not None});unprocessed=np.setdiff1d(ids,np.asarray(sampled,dtype=np.int64))
    source_coverage={
        "complete":False,"requested_triangle_count":len(ids),
        "processed_triangle_count":len(sampled),"processed_triangle_ranges":triangle_ranges(sampled),
        "unprocessed_triangle_count":len(unprocessed),"unprocessed_triangle_ranges":triangle_ranges(unprocessed),
        "source_samples_reusable":True,
        "sampling_fingerprint":canonical_digest([source.digest,ids.tolist(),budget]),
        "surface_interiors_sampled":True,"component_count":len(source.components),
        "component_guard_budget":max(1,budget//4),"guarantee":"sampled; no whole-cell acceptance claim"}
    m2c=_stats(source_rows,{"source_hash":context["source_hash"],**domains},{"geometry_hash":geometry_hash,"native_geometry_digest":native_digest,"boundary":"all exposed target faces"},units,source_coverage)
    c2m=_stats(cad_rows,{"model_ref":model_ref,"cad_face_refs":domains.get("cad_face_refs","all")},{"source_hash":context["source_hash"],"triangles":"all original triangles including interiors and lower-dimensional images"},units,cad_coverage)
    residuals=_residual_regions(source,source_rows,float(context["max_deviation"]),model_ref)
    if not faces and len(ids):
        residuals=[{"id":"unexplained-empty-"+canonical_digest([source.digest,group])[:20],"direction":"mesh_to_cad","category":"unexplained","triangle_ids":group,"sample_ids":[],"minimum_distance":None,"maximum_distance":None,"reason":"The current CAD boundary is empty","complete":True,"guarantee":"unavailable"} for group in connected_components(set(ids.tolist()),source.adjacency)]
    m2c["residual_regions"]=residuals;c2m["residual_regions"]=[]
    for face_ref in sorted({r["cad_entity_ref"] for r in cad_rows}):
        rows=[r for r in cad_rows if r["cad_entity_ref"]==face_ref and r["distance"]>context["max_deviation"]]
        if rows:
            c2m["residual_regions"].append({
                "id":"cad-residual-"+canonical_digest([geometry_hash,face_ref])[:20],"direction":"cad_to_mesh",
                "cad_entity_refs":[face_ref],"sample_ids":[r["id"] for r in rows],
                "triangle_ids":sorted({r["triangle_id"] for r in rows}),
                "minimum_distance":min(r["distance"] for r in rows),
                "maximum_distance":max(r["distance"] for r in rows),"complete":False,"guarantee":"sampled"})
    validity=_native_checks(shape,False);representation=_representation_strict(context,target,shape) if faces else {"kind":"reconstructed_representation","status":"not_evaluated","reason":"No current CAD boundary"}
    completion=check_requirements(context,target,_requirements(context,target,"completion_obligations"));invariants=check_requirements(context,target,_requirements(context,target,"active_invariants"));constraints=check_requirements(context,target,_requirements(context,target,"constraints"))
    feature_checks={"completion_obligations":completion,"active_invariants":invariants,"constraints":constraints,"observed_features":{"status":"not_evaluated","reason":"Protected source topology is a final-only computation"}}
    material={"available":False,"assumptions":policy.get("reference_interpretation",{"material":"unknown"}),"estimates_or_bounds":None,"ambiguous_regions":[],"reason":"Unsigned surface distances are supplied; signed material differences are not computed"}
    report={
        "comparison_id":None,"context_revision":context_revision,"source_hash":context["source_hash"],
        "model_ref":model_ref,"geometry_hash":geometry_hash,"native_geometry_digest":native_digest,
        "scope_requested":scope,
        "scope_completed":{"source_sample_count":len(sampled),"cad_sample_count":len(cad_rows),
                           "whole_continuous_cover":False},
        "scope_unknown":{"source_triangle_count":len(unprocessed),
                         "reverse_domain_unspecified":not whole and domains.get("cad_face_refs") is None},
        "quality_requested":quality,"units":units,"methods_used":methods,
        "geometry":{
            "mesh_to_cad":m2c,"cad_to_mesh":c2m,
            "symmetric":{"lower_bound":None,"upper_bound":None,"decision":"not_evaluated","guarantee":"sampled"},
            "discrepancies":residuals+c2m["residual_regions"]},
        "source_samples":source_rows,"validity_checks":validity,"representation_checks":[representation],
        "feature_checks":feature_checks,"material":material,
        "reference_assumptions":{
            "source":"immutable original triangle surface set",
            "comparison_arithmetic_margin":context.get("conversion_arithmetic_margin",0),
            "material_interpretation":policy.get("reference_interpretation",{"material":"unknown"})},
        "acceptance":"not_evaluated","limitations":limitations,
        "dependencies":{"context_revision":context_revision,"source_hash":context["source_hash"],
                        "geometry_hash":geometry_hash,"native_geometry_digest":native_digest,
                        "policy_fingerprint":canonical_digest(policy)},
        "provenance":{
            "parameters":{"scope":scope,"quality":quality},
            "algorithm_versions":{"compare":"iterative-compare-1","bounds":"adaptive-outward-native-surfaces-1"},
            "reference_samples":source_coverage["sampling_fingerprint"]}}
    if quality=="final" and whole:
        _final(context,target,shape,source,report)
    elif quality=="final":report["limitations"].append("A local comparison cannot approve whole-reconstruction acceptance")
    report["comparison_id"]="comparison-"+canonical_digest({k:v for k,v in report.items() if k!="comparison_id"})[:24]
    return report


def _final(context,target,shape,source,report):
    policy=context.get("policy",{});checks=[]
    settings=_settings(context)
    body=audit_body(shape,face_budget=int(settings.get("native_si_face_budget",2048)))
    report["validity_checks"]=body["checks"]
    if body["status"]=="fail":report["acceptance"]="fail";return
    if shape is None or not shape.Faces():report["acceptance"]="fail";return
    audit_source,feature_source,conversion_stable=_original_analysis(context,source)
    audit=_source_audit(audit_source,settings);report["reference_assumptions"]["source_audit"]={**audit,"predicates_frame":"original represented source coordinates before positive uniform unit conversion","working_incidence_preserved":conversion_stable}
    interpretation=policy.get("reference_interpretation",{})
    if not conversion_stable:checks.append({"kind":"reference_material_interpretation","status":"inconclusive","reason":"Unit conversion cannot preserve source incidence/feature resolution at the working precision"})
    elif interpretation.get("material")!="oriented_closed_boundary":checks.append({"kind":"reference_material_interpretation","status":"inconclusive","reason":"Reference material and cavity interpretation has not been accepted"})
    elif not audit["closed"] or not audit["orientation_consistent"] or audit["duplicate_faces"] or audit["nonmanifold_vertex_ids"]:checks.append({"kind":"reference_material_interpretation","status":"inconclusive","reason":"Source closure/orientation/manifold prerequisites remain unresolved"})
    elif audit["intersection_audit"]["status"]!="complete" or audit["intersection_audit"].get("pairs"):checks.append({"kind":"reference_material_interpretation","status":"inconclusive","reason":"Source embedding audit is incomplete or has intersections"})
    elif audit["component_count"]==1 and interpretation.get("nesting") in {"single_component","explicit"}:checks.append({"kind":"reference_material_interpretation","status":"pass","assumption":"One closed embedded orientable source boundary denotes its enclosed material"})
    elif interpretation.get("nesting")=="explicit" and audit["component_bounds_disjoint"]:checks.append({"kind":"reference_material_interpretation","status":"pass","assumption":"Explicit separate bodies with disjoint source boundary bounds"})
    else:checks.append({"kind":"reference_material_interpretation","status":"inconclusive","reason":"Nested/contacting source shell material semantics require an unsupported explicit shell interpretation"})
    if checks[-1]["status"]=="pass":
        expected=audit["euler_characteristics"];observed=_native_euler(shape);count=len(shape.Solids())
        checks.append({"kind":"interpreted_source_topology","status":"pass" if expected==observed and count==audit["component_count"] else "fail","source_euler_characteristics":expected,"cad_euler_characteristics":observed,"expected_body_count":audit["component_count"],"actual_body_count":count})
        report["feature_checks"]["observed_features"]=_protected_checks(feature_source,shape,context);checks.append(report["feature_checks"]["observed_features"])
    report["validity_checks"].extend(checks)
    circular=_circular_strip_check(context,feature_source,shape);report["representation_checks"].append(circular)
    all_checks=list(report["validity_checks"])+report["representation_checks"]
    for key in ("completion_obligations","active_invariants","constraints"):all_checks.extend(c for c in report["feature_checks"][key] if c.get("mandatory",True))
    if any(c["status"]=="fail" for c in all_checks):report["acceptance"]="fail";return
    from mesh_bounds import verify
    max_cells=settings.get("final_max_cells",100000)
    if type(max_cells) is not int or not 1<=max_cells<=2_000_000:raise ValueError("final_max_cells must be from 1 to 2,000,000")
    bounds=verify(source.faces,shape.copy(mesh=False),float(context["max_deviation"]),max_cells=max_cells,arithmetic_margin=float(context.get("conversion_arithmetic_margin",0)))
    report["methods_used"].append(bounds["report"]["error_verification_method"])
    for key,name in (("mesh_to_cad","source_to_result_deviation"),("cad_to_mesh","result_to_source_deviation")):
        value=bounds["report"][name];direction=report["geometry"][key]
        direction.update(lower_bound=value.get("lower_bound"),upper_bound=value.get("upper_bound"),guarantee="bounded" if value.get("complete") else "unavailable",continuous_coverage={"complete":value.get("complete"),"processed_cells":value.get("processed_cells")},bound_method=value.get("method"))
    lower=max(report["geometry"][k].get("lower_bound") or 0 for k in ("mesh_to_cad","cad_to_mesh"));uppers=[report["geometry"][k].get("upper_bound") for k in ("mesh_to_cad","cad_to_mesh")]
    geometric_pass=bounds["accepted"];geometric_fail=lower>context["max_deviation"]
    report["geometry"]["symmetric"]={"lower_bound":lower,"upper_bound":max(uppers) if all(v is not None for v in uppers) else None,"decision":"pass" if geometric_pass else "fail" if geometric_fail else "inconclusive","guarantee":"bounded" if geometric_pass else "partial_bounds"}
    report["geometry"]["verification_issues"]=bounds.get("issues",[])
    report["scope_completed"]["whole_continuous_cover"]=bool(geometric_pass)
    if settings.get("require_material_difference",False):all_checks.append({"status":"inconclusive","kind":"signed_material_difference"});report["limitations"].append("Mandatory signed material-difference bounds are not implemented")
    report["acceptance"]="fail" if geometric_fail else "pass" if geometric_pass and all(c["status"]=="pass" for c in all_checks) else "inconclusive"
