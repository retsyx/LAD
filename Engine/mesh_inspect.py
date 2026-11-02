"""Immutable, topology-aware evidence queries for iterative reconstruction.

No query edits the reference or CAD revision. Numerical measurements and sample
distances are observations, not a reconstruction acceptance certificate.
"""
from __future__ import annotations

from collections import OrderedDict
import copy
import hashlib
import heapq
import json
import math
from fractions import Fraction

import numpy as np

VERSION = "iterative-inspect-1"
_CACHE = OrderedDict()
_FULL = [[1.,0.,0.],[0.,1.,0.],[0.,0.,1.]]


class EvidenceError(ValueError):
    def __init__(self,code,message):
        super().__init__(message); self.code=code


def _hash(value):
    return hashlib.sha256(json.dumps(value,sort_keys=True,separators=(",",":"),allow_nan=False).encode()).hexdigest()


def diagnostic(code,message,*,severity="warning",recoverable=True,**extra):
    return {"code":code,"severity":severity,"message":message,"related_entity_refs":[],"evidence_refs":[],
            "recoverable":recoverable,"suggested_actions":[],**extra}


def _finite(value,name,nonnegative=False):
    if isinstance(value,bool) or not isinstance(value,(int,float)) or not math.isfinite(value) or nonnegative and value<0:
        raise EvidenceError("INVALID_QUERY",f"{name} must be a finite {'nonnegative ' if nonnegative else ''}number")
    return float(value)


def _vector(value,name,unit=False):
    if not isinstance(value,(list,tuple)) or len(value)!=3:raise EvidenceError("INVALID_QUERY",f"{name} requires xyz coordinates")
    result=np.asarray([_finite(x,name) for x in value])
    if unit:
        length=np.linalg.norm(result)
        if length<1e-15:raise EvidenceError("INVALID_QUERY",f"{name} must be nonzero")
        result/=length
    return result


def _frame(normal,x_direction=None):
    normal=np.asarray(normal,float);normal/=np.linalg.norm(normal)
    x=np.eye(3)[int(np.argmin(np.abs(normal)))] if x_direction is None else np.asarray(x_direction,float)
    x=x-normal*float(x@normal)
    if np.linalg.norm(x)<1e-12:raise EvidenceError("INVALID_QUERY","Plane x direction must be independent of its normal")
    x/=np.linalg.norm(x)
    return x,np.cross(normal,x),normal


def _query_policy(context):
    policy=context.get("query_policy",context.get("policy",{}).get("query_policy",{}))
    limits={"max_triangles":(1,1_000_000,1_000_000),"max_planes":(1,64,64),"max_growth_visits":(1,1_000_000,1_000_000)}
    if not isinstance(policy,dict) or set(policy)-set(limits):raise EvidenceError("INVALID_POLICY","Unknown query_policy field")
    result={}
    for key,(low,high,default) in limits.items():
        value=policy.get(key,default)
        if type(value) is not int or not low<=value<=high:raise EvidenceError("INVALID_POLICY",f"{key} must be an integer from {low} to {high}")
        result[key]=value
    return result


def _analysis(context):
    """Return cached read-only derived arrays; original IDs and coordinates stay fixed."""
    if not isinstance(context,dict) or not isinstance(context.get("id"),str) or not isinstance(context.get("source_hash"),str):
        raise EvidenceError("INVALID_CONTEXT","A context requires id and source_hash")
    vertices=np.asarray(context.get("vertices"),float);raw=np.asarray(context.get("triangles"))
    if vertices.ndim!=2 or vertices.shape[1:]!=(3,) or len(vertices)<3 or not np.isfinite(vertices).all():
        raise EvidenceError("INVALID_CONTEXT","Reference vertices must be finite xyz coordinates")
    if raw.ndim!=2 or raw.shape[1:]!=(3,) or len(raw)==0 or raw.dtype.kind not in "iu" or raw.min()<0 or raw.max()>=len(vertices):
        raise EvidenceError("INVALID_CONTEXT","Reference triangles require three valid integer indices")
    if len(raw)>1_000_000:raise EvidenceError("RESOURCE_LIMIT","Reference triangle count exceeds one million")
    triangles=raw.astype(np.int64)
    geometry_hash=hashlib.sha256(vertices.tobytes()+triangles.tobytes()).hexdigest()
    key=(context["id"],context["source_hash"],geometry_hash)
    if key in _CACHE:
        _CACHE.move_to_end(key);return _CACHE[key]
    vertices=vertices.copy();triangles=triangles.copy()
    low,high=vertices.min(axis=0),vertices.max(axis=0);scale=float(np.linalg.norm(high-low))
    if not math.isfinite(scale) or scale<=0:raise EvidenceError("INVALID_CONTEXT","Reference has no finite spatial extent")
    normalized=(vertices-low)/scale;faces=vertices[triangles]
    cross=np.cross(normalized[triangles[:,1]]-normalized[triangles[:,0]],normalized[triangles[:,2]]-normalized[triangles[:,0]])
    length=np.linalg.norm(cross,axis=1)
    normals=np.divide(cross,length[:,None],out=np.zeros_like(cross),where=length[:,None]>0)
    areas=length*scale*scale/2
    unique,representative,inverse=np.unique(vertices,axis=0,return_index=True,return_inverse=True)
    welded=inverse[triangles];edges={};adjacency=[set() for _ in triangles];triangle_edges=[[] for _ in triangles]
    for tid,face in enumerate(welded.tolist()):
        if areas[tid]==0:continue
        for a,b in zip(face,face[1:]+face[:1]):
            edge=(min(a,b),max(a,b));edges.setdefault(edge,[]).append((tid,a<b));triangle_edges[tid].append(edge)
    for edge,uses in edges.items():
        if len(uses)==2:
            a,b=uses[0][0],uses[1][0];adjacency[a].add(b);adjacency[b].add(a)
    components=_components(range(len(triangles)),adjacency)
    result={"vertices":vertices,"triangles":triangles,"faces":faces,"normals":normals,"areas":areas,"centroids":faces.mean(axis=1),
            "adjacency":adjacency,"components":components,"edges":edges,"triangle_edges":triangle_edges,"welded_vertices":unique,
            "welded_triangles":welded,"representative_vertices":representative,"geometry_hash":geometry_hash,"scale":scale,
            "bounds":{"min":low.tolist(),"max":high.tolist()},"degenerate_triangles":np.flatnonzero(areas==0).tolist()}
    for value in result.values():
        if isinstance(value,np.ndarray):value.setflags(write=False)
    _CACHE[key]=result
    while len(_CACHE)>4:_CACHE.popitem(last=False)
    return result


def _components(ids,adjacency):
    remaining=set(int(x) for x in ids);groups=[]
    while remaining:
        seed=min(remaining);remaining.remove(seed);stack=[seed];group=[]
        while stack:
            current=stack.pop();group.append(current)
            for neighbor in adjacency[current]:
                if neighbor in remaining:remaining.remove(neighbor);stack.append(neighbor)
        groups.append(sorted(group))
    return groups


def _indices(values,count):
    if not isinstance(values,(list,tuple)) or any(type(x) is not int or not 0<=x<count for x in values):
        raise EvidenceError("INVALID_SELECTION","Triangle IDs must be original bounded integer IDs")
    return sorted(set(values))


def _selection(record,context,resolve):
    if isinstance(record,str):
        if resolve is None:raise EvidenceError("STALE_REFERENCE","Evidence reference cannot be resolved")
        record=resolve(record)
        if isinstance(record,dict) and "payload" in record:record=record["payload"]
    if not isinstance(record,dict):raise EvidenceError("INVALID_SELECTION","Expected an evidence record or reference")
    if "evidence_ref" in record:return _selection(record["evidence_ref"],context,resolve)
    if record.get("source_hash",context["source_hash"])!=context["source_hash"] or record.get("context_ref",context["id"])!=context["id"]:
        raise EvidenceError("STALE_REFERENCE","Evidence belongs to a different immutable source context")
    members=record.get("selection",{}).get("source_members")
    if members is None:
        ids=record.get("triangle_ids",record.get("source_triangles",record.get("source_selection",{}).get("triangle_ids",[])))
        return {i:[copy.deepcopy(_FULL)] for i in _indices(ids,len(context["triangles"]))}
    result={}
    if not isinstance(members,list):raise EvidenceError("INVALID_SELECTION","source_members must be a list")
    for member in members:
        tid=member.get("triangle_id");_indices([tid],len(context["triangles"]))
        polygons=member.get("barycentric_polygons",[member.get("barycentric_polygon",_FULL)])
        if not isinstance(polygons,list):raise EvidenceError("INVALID_SELECTION","Invalid barycentric polygons")
        for polygon in polygons:
            array=np.asarray(polygon,float)
            if array.ndim!=2 or array.shape[1:]!=(3,) or len(array)<3 or not np.isfinite(array).all() or array.min()<-1e-10 or np.max(np.abs(array.sum(axis=1)-1))>1e-9:
                raise EvidenceError("INVALID_SELECTION","Clipped selections require finite simplex coordinates")
        result.setdefault(tid,[]).extend(copy.deepcopy(polygons))
    return result


def _clip(polygon,distance,inside=True):
    result=[];previous=polygon[-1];a=distance(previous)
    if not inside:a=-a
    for current in polygon:
        b=distance(current)
        if not inside:b=-b
        if (a>=0)!=(b>=0):
            t=a/(a-b);result.append((np.asarray(previous)+t*(np.asarray(current)-previous)).tolist())
        if b>=0:result.append(list(current))
        previous,a=current,b
    # Only suppress duplicate representations of the same clipping event.
    cleaned=[]
    for point in result:
        if not cleaned or not np.array_equal(point,cleaned[-1]):cleaned.append(point)
    if len(cleaned)>1 and np.array_equal(cleaned[0],cleaned[-1]):cleaned.pop()
    return cleaned if len(cleaned)>=3 else []


def _polygon_intersection(subject,clipper):
    polygon=subject
    xy=np.asarray(clipper)[:,1:];area=float(np.sum(xy[:,0]*np.roll(xy[:,1],-1)-xy[:,1]*np.roll(xy[:,0],-1)))
    sign=1 if area>=0 else -1
    for a,b in zip(xy,np.roll(xy,-1,axis=0)):
        polygon=_clip(polygon,lambda p:sign*((b[0]-a[0])*(p[2]-a[1])-(b[1]-a[1])*(p[1]-a[0]))) if polygon else []
    return polygon


def _polygon_difference(subject,clipper):
    remaining=subject;result=[];xy=np.asarray(clipper)[:,1:]
    sign=1 if np.sum(xy[:,0]*np.roll(xy[:,1],-1)-xy[:,1]*np.roll(xy[:,0],-1))>=0 else -1
    for a,b in zip(xy,np.roll(xy,-1,axis=0)):
        if not remaining:break
        distance=lambda p:sign*((b[0]-a[0])*(p[2]-a[1])-(b[1]-a[1])*(p[1]-a[0]))
        outside=_clip(remaining,distance,False)
        if outside:result.append(outside)
        remaining=_clip(remaining,distance)
    return result


def _set_operation(first,second,operation):
    result={}
    for tid in sorted(set(first)|set(second)):
        a,b=first.get(tid,[]),second.get(tid,[])
        def difference(parts,cutters):
            parts=copy.deepcopy(parts)
            for cutter in cutters:parts=[fragment for part in parts for fragment in _polygon_difference(part,cutter)]
            return parts
        if operation=="intersection":parts=[p for x in a for y in b if (p:=_polygon_intersection(x,y))]
        elif operation=="difference":parts=difference(a,b)
        elif operation=="union":parts=copy.deepcopy(a)+difference(b,a)
        elif operation=="symmetric_difference":parts=difference(a,b)+difference(b,a)
        else:raise EvidenceError("INVALID_QUERY","Unknown selection set operation")
        if parts:result[tid]=parts
    return result


def _closest_triangle(point,face):
    a,b,c=face;ab=b-a;ac=c-a;ap=point-a
    matrix=np.array([[ab@ab,ab@ac],[ab@ac,ac@ac]])
    candidates=[]
    if abs(float(np.linalg.det(matrix)))>1e-30:
        u,v=np.linalg.solve(matrix,[ap@ab,ap@ac])
        if u>=0 and v>=0 and u+v<=1:candidates.append(np.array([1-u-v,u,v]))
    for i,j in ((0,1),(1,2),(2,0)):
        edge=face[j]-face[i];length=float(edge@edge);t=float(np.clip((point-face[i])@edge/length,0,1)) if length>0 else 0.
        bary=np.zeros(3);bary[i]=1-t;bary[j]=t;candidates.append(bary)
    return min(candidates,key=lambda bary:float(np.linalg.norm(point-bary@face)))


def _resolve_select(context,analysis,query,resolve):
    count=len(analysis["triangles"]);hit=None
    if "evidence_ref" in query:return _selection(query,context,resolve),hit
    if "source_triangles" in query or "triangle_ids" in query:return _selection(query,context,resolve),hit
    if "source_triangle" in query:return {i:[copy.deepcopy(_FULL)] for i in _indices([query["source_triangle"]],count)},hit
    if query.get("scope")=="all" and not any(key in query for key in ("predicate","box","normal","ray","point")):
        return {i:[copy.deepcopy(_FULL)] for i in range(count)},hit
    if "ray" in query:
        ray=query["ray"];origin=_vector(ray.get("origin"),"ray origin");direction=_vector(ray.get("direction"),"ray direction",True)
        faces=analysis["faces"];edge1=faces[:,1]-faces[:,0];edge2=faces[:,2]-faces[:,0]
        cross=np.cross(direction,edge2);det=np.einsum("ij,ij->i",edge1,cross)
        inv=np.divide(1,det,out=np.zeros_like(det),where=np.abs(det)>1e-15)
        delta=origin-faces[:,0];u=np.einsum("ij,ij->i",delta,cross)*inv;cross2=np.cross(delta,edge1)
        v=cross2@direction*inv;distance=np.einsum("ij,ij->i",edge2,cross2)*inv
        valid=np.flatnonzero((np.abs(det)>1e-15)&(u>=0)&(v>=0)&(u+v<=1)&(distance>=0))
        if not len(valid):return {},None
        tid=int(min(valid,key=lambda i:(distance[i],i)))
        bary=[float(1-u[tid]-v[tid]),float(u[tid]),float(v[tid])]
        hit={"triangle_id":tid,"barycentric":bary,"position":(np.asarray(bary)@faces[tid]).tolist(),"distance":float(distance[tid]),"method":"nearest_forward_ray_triangle_intersection"}
        return {tid:[copy.deepcopy(_FULL)]},hit
    if "point" in query:
        point=_vector(query["point"],"selection point");radius=_finite(query.get("radius"),"selection radius",True)
        distances=np.linalg.norm(analysis["centroids"]-point,axis=1);bounds=np.max(np.linalg.norm(analysis["faces"]-analysis["centroids"][:,None],axis=2),axis=1)
        possible=np.flatnonzero(distances-bounds<=radius);best=None
        for tid in possible:
            bary=_closest_triangle(point,analysis["faces"][tid]);position=bary@analysis["faces"][tid];distance=float(np.linalg.norm(position-point))
            if distance<=radius and (best is None or distance<best[0]):best=(distance,int(tid),bary,position)
        if best is None:return {},None
        distance,tid,bary,position=best;return {tid:[copy.deepcopy(_FULL)]},{"triangle_id":tid,"barycentric":bary.tolist(),"position":position.tolist(),"distance":distance}
    predicate=query.get("predicate",{"kind":"box",**query["box"]} if "box" in query else None)
    if predicate:
        if predicate.get("kind")!="box":raise EvidenceError("UNSUPPORTED_QUERY","Supported spatial predicate is an explicit box")
        low=_vector(predicate.get("min"),"box minimum");high=_vector(predicate.get("max"),"box maximum")
        if np.any(low>high):raise EvidenceError("INVALID_QUERY","Box limits are reversed")
        mode=predicate.get("mode","intersects")
        if mode not in ("inside","intersects","clip"):raise EvidenceError("INVALID_QUERY","Box mode must be inside, intersects or clip")
        faces=analysis["faces"];possible=np.flatnonzero(np.all(faces.max(axis=1)>=low,axis=1)&np.all(faces.min(axis=1)<=high,axis=1));result={}
        for tid in possible.tolist():
            face=faces[tid];polygon=copy.deepcopy(_FULL)
            if mode=="inside":
                if np.all(face>=low) and np.all(face<=high):result[tid]=[polygon]
                continue
            for axis in range(3):
                for bound,sign in ((low[axis],1),(high[axis],-1)):
                    if polygon:polygon=_clip(polygon,lambda bary:sign*(np.asarray(bary)@face[:,axis]-bound))
            if polygon:result[tid]=[polygon if mode=="clip" else copy.deepcopy(_FULL)]
        return result,hit
    if "normal" in query:
        predicate=query["normal"];direction=_vector(predicate.get("direction"),"normal direction",True);angle=_finite(predicate.get("angle",.1),"normal angle",True)
        dot=analysis["normals"]@direction
        if not predicate.get("oriented",False):dot=np.abs(dot)
        return {int(i):[copy.deepcopy(_FULL)] for i in np.flatnonzero((dot>=math.cos(angle))&(analysis["areas"]>0))},hit
    raise EvidenceError("INVALID_QUERY","Selection requires original triangle IDs, a predicate, ray, bounded point, or scope all")


def _grow(context,analysis,query,resolve,shrink=False):
    raw=query.get("selection",query.get("seed",{"evidence_ref":query.get("evidence_ref")}))
    if isinstance(raw,str) or isinstance(raw,dict) and "evidence_ref" in raw:selection=_selection(raw,context,resolve)
    else:selection,_hit=_resolve_select(context,analysis,raw,resolve)
    distance=_finite(query.get("distance",query.get("max_geodesic_distance",analysis["scale"])),"growth distance",True)
    barriers=query.get("barriers",["boundary","nonmanifold","sharp_feature"])
    if not isinstance(barriers,list) or set(barriers)-{"boundary","nonmanifold","sharp_feature"}:raise EvidenceError("INVALID_QUERY","Unknown growth barrier")
    angle=_finite(query.get("sharp_angle",math.pi/6),"sharp angle",True);coherence=query.get("coherence",{})
    reference=np.mean(analysis["normals"][sorted(selection)],axis=0) if selection else np.zeros(3)
    if np.linalg.norm(reference)>0:reference/=np.linalg.norm(reference)
    stopped=[];selected=set(selection);adj=analysis["adjacency"]
    if shrink and distance==0:return selection,stopped
    if shrink:
        seeds=[tid for tid in selected if any(len(analysis["edges"][edge])!=2 or any(other not in selected for other,_ in analysis["edges"][edge]) for edge in analysis["triangle_edges"][tid])]
    else:seeds=sorted(selected)
    heap=[(0.,tid) for tid in seeds];heapq.heapify(heap);seen={tid:0. for tid in seeds};visited=set()
    visit_limit=_query_policy(context)["max_growth_visits"]
    while heap:
        if len(visited)>=visit_limit:
            stopped.append({"reason":"work_budget","frontier_triangle_ids":sorted({tid for cost,tid in heap if cost<=distance})});break
        cost,current=heapq.heappop(heap)
        if current in visited or cost>distance:continue
        visited.add(current)
        for edge in analysis["triangle_edges"][current]:
            uses=analysis["edges"][edge]
            if len(uses)>2:stopped.append({"edge":list(edge),"reason":"nonmanifold_ambiguity","incident_triangles":[tid for tid,_ in uses]})
            elif len(uses)==1 and "boundary" in barriers:stopped.append({"edge":list(edge),"reason":"source_boundary"})
        for neighbor in sorted(adj[current]):
            if shrink and neighbor not in selected:continue
            dot=float(np.clip(analysis["normals"][current]@analysis["normals"][neighbor],-1,1))
            if "sharp_feature" in barriers and dot<math.cos(angle):
                stopped.append({"triangles":[current,neighbor],"reason":"sharp_feature"});continue
            if "normal_change" in coherence and float(analysis["normals"][neighbor]@reference)<math.cos(_finite(coherence["normal_change"],"coherence angle",True)):
                stopped.append({"triangles":[current,neighbor],"reason":"anchored_normal_coherence"});continue
            if "plane" in coherence:
                plane=coherence["plane"];normal=_vector(plane["normal"],"coherence plane normal",True);origin=_vector(plane["origin"],"coherence plane origin")
                if np.max(np.abs((analysis["faces"][neighbor]-origin)@normal))>_finite(coherence.get("distance",0),"coherence distance",True):continue
            new=cost+float(np.linalg.norm(analysis["centroids"][current]-analysis["centroids"][neighbor]))
            if new<seen.get(neighbor,math.inf):seen[neighbor]=new;heapq.heappush(heap,(new,neighbor))
    if shrink:return {tid:parts for tid,parts in selection.items() if tid not in visited},stopped
    return {tid:copy.deepcopy(selection.get(tid,[_FULL])) for tid in selected|visited},stopped


def _measure(analysis,selection):
    total=0.;first=np.zeros(3);second=np.zeros((3,3));positions=[]
    for tid,polygons in selection.items():
        for polygon in polygons:
            points=np.asarray(polygon)@analysis["faces"][tid];positions.extend(points)
            for i in range(1,len(points)-1):
                face=points[[0,i,i+1]];area=float(np.linalg.norm(np.cross(face[1]-face[0],face[2]-face[0]))/2)
                center=face.mean(axis=0);total+=area;first+=area*center
                second+=area*(sum(np.outer(p,p) for p in face)+np.outer(face.sum(axis=0),face.sum(axis=0)))/12
    if not positions:return {"area":0.,"centroid":None,"bounds":None,"principal_axes":None,"guarantee":"floating_point_measurement"}
    positions=np.asarray(positions);centroid=first/total if total>0 else positions.mean(axis=0)
    covariance=second/total-np.outer(centroid,centroid) if total>0 else np.zeros((3,3))
    values,vectors=np.linalg.eigh((covariance+covariance.T)/2)
    return {"area":total,"centroid":centroid.tolist(),"bounds":{"min":positions.min(axis=0).tolist(),"max":positions.max(axis=0).tolist()},
            "principal_axes":{"eigenvalues":np.maximum(values,0).tolist(),"directions":vectors.T.tolist(),"ambiguous":bool(values[-1]<=0 or min(np.diff(values))<max(values[-1],1e-30)*1e-5)},
            "guarantee":"floating_point_measurement","area_units":"square_context_units"}


def _boundary(analysis,selection):
    selected=set(selection);result=[]
    for edge,uses in analysis["edges"].items():
        owners=[tid for tid,_ in uses if tid in selected]
        if owners and (len(uses)!=2 or len(owners)!=2):
            result.append({"edge_vertices":[int(analysis["representative_vertices"][v]) for v in edge],"triangle_ids":owners,
                           "kind":"nonmanifold" if len(uses)>2 else "source_boundary" if len(uses)==1 else "selection_boundary"})
    return result


def _member(tid,parts):
    return {"triangle_id":int(tid)} if len(parts)==1 and np.array_equal(parts[0],_FULL) else {"triangle_id":int(tid),"barycentric_polygons":parts}


def _source_sections(analysis,selection,plane):
    origin=_vector(plane.get("origin"),"section origin");raw_normal=_vector(plane.get("normal"),"section normal");normal=_vector(plane.get("normal"),"section normal",True)
    x,y,normal=_frame(normal,plane.get("x_direction"));events={};segments=[];contacts=[];coplanar=[]
    def signed(tid,bary):
        point=np.asarray(bary)@analysis["faces"][tid];offset=point-origin;value=float(offset@raw_normal)
        bound=32*np.finfo(float).eps*float(np.sum(np.abs(offset*raw_normal))+np.sum(np.abs(point)*np.abs(raw_normal)))
        if abs(value)>bound:return value
        exact=sum((sum(Fraction(float(bary[j]))*Fraction(float(analysis["faces"][tid,j,i])) for j in range(3))-Fraction(float(origin[i])))*Fraction(float(raw_normal[i])) for i in range(3))
        return exact
    def key(tid,bary):
        nonzero=np.flatnonzero(np.abs(bary)>1e-14)
        welded=analysis["welded_triangles"][tid]
        if len(nonzero)==1:return ("vertex",int(welded[nonzero[0]]))
        if len(nonzero)==2:
            ids=sorted(int(welded[i]) for i in nonzero)
            a,b=[analysis["welded_vertices"][i] for i in ids]
            if float((a-origin)@raw_normal)==0 and float((b-origin)@raw_normal)==0:
                local=int(np.flatnonzero(welded==ids[1])[0]);return ("edge_point",*ids,float(bary[local]))
            return ("edge",*ids)
        return ("interior",int(tid),*tuple(float(v) for v in bary))
    for tid,polygons in selection.items():
        for polygon in polygons:
            bary=np.asarray(polygon,float);points=bary@analysis["faces"][tid];distance=[signed(tid,b) for b in bary]
            # Exact represented arithmetic is used for zero, without snapping a
            # physical near-plane band into the requested section.
            if all(value==0 for value in distance):coplanar.append({"triangle_id":tid,"barycentric_polygon":polygon});continue
            found=[]
            for i,j in zip(range(len(points)),list(range(1,len(points)))+[0]):
                a,b=distance[i],distance[j]
                if a==0:found.append(bary[i])
                if a*b<0:found.append(bary[i]+float(a/(a-b))*(bary[j]-bary[i]))
            unique={key(tid,b):b for b in found}
            for identity,b in unique.items():
                position=b@analysis["faces"][tid]
                events.setdefault(identity,{"position":position.tolist(),"provenance":[]})["provenance"].append({"triangle_id":tid,"barycentric":b.tolist()})
            keys=list(unique)
            if len(keys)==2:segments.append({"endpoints":keys,"triangle_id":tid,"barycentric_endpoints":[unique[k].tolist() for k in keys]})
            elif len(keys)==1:contacts.append(keys[0])
    # Coplanar area boundaries retain multiplicity, suppressing only true
    # internal edges of two selected coplanar source faces.
    coplanar_edges={}
    for item in coplanar:
        tid=item["triangle_id"];polygon=item["barycentric_polygon"]
        for a,b in zip(polygon,polygon[1:]+polygon[:1]):
            ends=[key(tid,np.asarray(value)) for value in (a,b)]
            for identity,bary in zip(ends,(a,b)):
                events.setdefault(identity,{"position":(np.asarray(bary)@analysis["faces"][tid]).tolist(),"provenance":[]})["provenance"].append({"triangle_id":tid,"barycentric":bary})
            coplanar_edges.setdefault(tuple(sorted(ends)),[]).append({"endpoints":ends,"triangle_id":tid,"barycentric_endpoints":[a,b],"kind":"coplanar_boundary"})
    for uses in coplanar_edges.values():
        if len(uses)==2 and uses[1]["triangle_id"] in analysis["adjacency"][uses[0]["triangle_id"]]:continue
        segments.extend(uses)
    graph={};dedup={}
    for segment in segments:
        a,b=segment["endpoints"];identity=tuple(sorted((a,b)))
        dedup.setdefault(identity,[]).append(segment)
    for a,b in dedup:graph.setdefault(a,set()).add(b);graph.setdefault(b,set()).add(a)
    remaining=set(dedup);curves=[];branches=[event for event,neighbors in graph.items() if len(neighbors)>2]
    for seed in sorted(graph,key=lambda k:(len(graph[k])==2,k)):
        for following in sorted(graph[seed]):
            if tuple(sorted((seed,following))) not in remaining:continue
            chain=[seed];used=[];previous,current=seed,following
            while True:
                edge=tuple(sorted((previous,current)))
                if edge not in remaining:break
                remaining.remove(edge);used.extend(dedup[edge]);chain.append(current)
                if current==seed or len(graph[current])!=2:break
                other=next(v for v in graph[current] if v!=previous);previous,current=current,other
            positions=[events[event]["position"] for event in chain]
            curves.append({"closed":chain[-1]==chain[0],"points":positions,"parameters":[[(np.asarray(p)-origin)@x,(np.asarray(p)-origin)@y] for p in positions],
                           "source_segments":[{k:v for k,v in segment.items() if k!="endpoints"} for segment in used],"guarantee":"floating_point_intersection_with_original_topology"})
    isolated=[events[k] for k in set(contacts) if k not in graph]
    multiplicity=[{"triangle_ids":sorted({segment["triangle_id"] for segment in uses}),"kind":"coincident_segment_multiplicity"}
                  for uses in dedup.values() if len({segment["triangle_id"] for segment in uses})>2]
    return {"plane":{"origin":origin.tolist(),"normal":raw_normal.tolist()},"frame":{"x_direction":x.tolist(),"y_direction":y.tolist()},"curves":curves,
            "points":isolated,"coplanar_regions":coplanar,"branches":[events[k] for k in branches],"ambiguities":multiplicity,
            "predicate_policy":"filtered exact rational signs on represented source coordinates; binary64 intersection construction",
            "source":"reference","closed_sketch_inferred":False}


def _cad_section(shape,plane):
    from OCP.BRepAlgoAPI import BRepAlgoAPI_Section
    from OCP.gp import gp_Pln,gp_Pnt,gp_Dir
    import cadquery as cq
    origin=_vector(plane["origin"],"section origin");normal=_vector(plane["normal"],"section normal",True)
    algorithm=BRepAlgoAPI_Section(shape.wrapped,gp_Pln(gp_Pnt(*origin),gp_Dir(*normal)),False);algorithm.SetNonDestructive(True);algorithm.Build()
    if not algorithm.IsDone():raise EvidenceError("NUMERICAL_FAILURE","Native CAD section failed")
    edges=cq.Shape.cast(algorithm.Shape()).Edges();result=[]
    for edge in edges:
        count=max(2,min(257,int(edge.Length()/max(1e-5,edge.Length()/64))+1))
        positions=[edge.positionAt(float(t)).toTuple() for t in np.linspace(0,1,count)]
        result.append({"closed":edge.IsClosed(),"points":[list(p) for p in positions],"geometry_type":edge.geomType(),"length":edge.Length(),"guarantee":"kernel_intersection_display_sampling"})
    return {"source":"cad","plane":copy.deepcopy(plane),"curves":result,"points":[],"coplanar_regions":[],"closed_sketch_inferred":False}


def inspect(context,revision,query,resolve_evidence=None):
    provenance={"context_ref":context.get("id") if isinstance(context,dict) else None,"source_hash":context.get("source_hash") if isinstance(context,dict) else None,
                "dependency_revisions":[],"parameters":copy.deepcopy(query),"algorithm_versions":{"inspect":VERSION},"numerical_policy":"binary64 measurements; no final acceptance claim","seed":0}
    try:
        analysis=_analysis(context);policy=_query_policy(context)
        if not isinstance(query,dict):raise EvidenceError("INVALID_QUERY","Inspection query must be an object")
        if not isinstance(revision,dict) or not isinstance(revision.get("id"),str):raise EvidenceError("STALE_REFERENCE","Inspect requires an exact CAD revision, including an empty r0")
        kind=query.get("kind");diagnostics=[];stopped=[];sections=[];hit=None;partition_groups=None;cad_used=False;cad_members=[];cad_measurements=None;unknown_scope=set()
        if kind=="select" and "cad_entities" in query:
            refs=query["cad_entities"]
            if not isinstance(refs,list) or not refs or not all(isinstance(ref,str) for ref in refs):raise EvidenceError("INVALID_QUERY","CAD selection requires explicit semantic entity references")
            state=revision.get("state",revision);available=revision.get("entities",{})
            body_ids=state.get("body_ids",[]);features=state.get("features",{});constructions=state.get("constructions",{})
            for ref in refs:
                if ref not in available and ref not in body_ids and ref not in features and ref not in constructions:raise EvidenceError("STALE_REFERENCE","The exact revision has no semantic CAD entity "+ref)
                category="body" if ref in body_ids else "construction" if ref in constructions else "feature"
                cad_members.append({"entity_ref":ref,"cad_revision":revision["id"],"category":category})
                if category=="feature" and ref not in available:diagnostics.append(diagnostic("CAD_FEATURE_TOPOLOGY_UNRESOLVED","Feature identity is retained, but no unique current native face binding was supplied",related_entity_refs=[ref]))
            selection={};cad_used=True
        elif kind=="select":selection,hit=_resolve_select(context,analysis,query,resolve_evidence)
        elif kind in ("grow","shrink"):selection,stopped=_grow(context,analysis,query,resolve_evidence,kind=="shrink")
        elif kind=="combine":
            refs=query.get("selections",query.get("evidence_refs",[]))
            if not isinstance(refs,list) or not 1<=len(refs)<=32:raise EvidenceError("INVALID_QUERY","Combine requires 1..32 evidence selections")
            selection=_selection(refs[0],context,resolve_evidence)
            for item in refs[1:]:selection=_set_operation(selection,_selection(item,context,resolve_evidence),query.get("operation","union"))
        elif kind in ("partition","section","measure","discrepancies"):
            scope=query.get("selection",query.get("scope","all"))
            selection={i:[copy.deepcopy(_FULL)] for i in range(len(analysis["triangles"]))} if scope=="all" else _selection(scope,context,resolve_evidence)
            if kind=="partition":
                separator=query.get("separator")
                if separator:
                    origin=_vector(separator["origin"],"partition plane origin");normal=_vector(separator["normal"],"partition plane normal",True)
                    sides=[{},{}]
                    for tid,parts in selection.items():
                        for part in parts:
                            distance=lambda bary:(np.asarray(bary)@analysis["faces"][tid]-origin)@normal
                            for i,sign in enumerate((1,-1)):
                                polygon=_clip(part,lambda bary:sign*distance(bary))
                                if polygon:sides[i].setdefault(tid,[]).append(polygon)
                    partition_groups=[part for part in sides if part]
                else:partition_groups=[{i:selection[i] for i in group} for group in _components(selection,analysis["adjacency"])]
            elif kind=="section":
                planes=query.get("planes",[query.get("plane")]);source=query.get("source","reference")
                if not isinstance(planes,list) or not 1<=len(planes)<=policy["max_planes"] or not all(isinstance(p,dict) for p in planes):raise EvidenceError("INVALID_QUERY","Section planes exceed the declared query policy or are invalid")
                if source not in ("reference","source","cad","both"):raise EvidenceError("INVALID_QUERY","Unknown section source")
                for plane in planes:
                    if source in ("reference","source","both"):sections.append(_source_sections(analysis,selection,plane))
                    if source in ("cad","both"):
                        cad_used=True
                        if revision.get("_shape") is None:
                            diagnostics.append(diagnostic("CAD_UNAVAILABLE","The empty CAD revision has no section geometry"));sections.append({"source":"cad","plane":plane,"curves":[],"points":[],"unavailable":"empty_cad"})
                        else:sections.append(_cad_section(revision["_shape"],plane))
            elif kind=="discrepancies":
                cad_used=True;comparison=revision.get("comparison")
                if revision.get("_shape") is None:
                    diagnostics.append(diagnostic("CAD_UNAVAILABLE","Source remains unexplained; distance to an empty CAD boundary is unavailable"))
                elif not comparison:
                    diagnostics.append(diagnostic("COMPARISON_UNAVAILABLE","No current comparison covers this selection; refresh it through compare"))
                else:
                    direction=comparison.get("geometry",{}).get("mesh_to_cad",{})
                    source_samples=comparison.get("source_samples",direction.get("samples",comparison.get("discrepancies",[])))
                    threshold=_finite(query.get("minimum_residual",context.get("max_deviation",0)),"minimum residual",True)
                    ids={s["triangle_id"] for s in source_samples if isinstance(s,dict) and "triangle_id" in s and s.get("distance") is not None and s["distance"]>=threshold}
                    selection={tid:parts for tid,parts in selection.items() if tid in ids}
                    coverage=direction.get("coverage",{})
                    if not coverage.get("complete",False):
                        unknown_scope.update(coverage.get("unprocessed_triangle_ids",[]))
                        diagnostics.append(diagnostic("COMPARISON_PARTIAL","Discrepancy selection covers only processed source samples; other source triangles remain unknown"))
            elif kind=="measure" and query.get("source") in ("cad","both"):
                cad_used=True;shape=revision.get("_shape")
                if shape is None:diagnostics.append(diagnostic("CAD_UNAVAILABLE","The empty revision has no native CAD measurements"))
                else:
                    bounds=shape.BoundingBox();solids=shape.Solids()
                    cad_measurements={"area":float(shape.Area()),"volume":float(shape.Volume()) if solids else None,"centroid":list(shape.Center().toTuple()),
                                      "bounds":{"min":[bounds.xmin,bounds.ymin,bounds.zmin],"max":[bounds.xmax,bounds.ymax,bounds.zmax]},
                                      "method":"native_analytic_integrals","guarantee":"kernel_numeric","cad_revision":revision["id"]}
        else:raise EvidenceError("UNSUPPORTED_QUERY",f"Unsupported inspect query kind: {kind}")
        maximum=query.get("limit",policy["max_triangles"])
        if type(maximum) is not int or not 1<=maximum<=policy["max_triangles"]:raise EvidenceError("INVALID_QUERY","Selection limit exceeds query_policy.max_triangles or is invalid")
        omitted=[]
        if len(selection)>maximum:
            keys=sorted(selection);omitted=keys[maximum:];selection={i:selection[i] for i in keys[:maximum]}
            diagnostics.append(diagnostic("BUDGET_EXHAUSTED","Selection was truncated; omitted source geometry is not explained"))
        for record in stopped:
            if record["reason"]=="work_budget":
                unknown_scope.update(record["frontier_triangle_ids"]);diagnostics.append(diagnostic("BUDGET_EXHAUSTED","Growth frontier budget exhausted; reachable unprocessed geometry remains unknown"))
        members=[_member(tid,parts) for tid,parts in sorted(selection.items())]
        if partition_groups is None:partition_groups=[{i:selection[i] for i in group} for group in _components(selection,analysis["adjacency"])]
        regions=[]
        for group in partition_groups:
            entries=[_member(i,parts) for i,parts in sorted(group.items()) if i in selection]
            if not entries:continue
            regions.append({"region_id":"region-"+_hash([context["source_hash"],entries])[:24],"triangle_ids":[m["triangle_id"] for m in entries],"source_members":entries,
                            "measurements":_measure(analysis,{i:parts for i,parts in group.items() if i in selection}),"boundary":_boundary(analysis,group)})
        dependencies={"context_ref":context["id"],"source_hash":context["source_hash"],"source_geometry_hash":analysis["geometry_hash"]}
        if cad_used:dependencies["cad_revision"]=revision["id"];provenance["dependency_revisions"]=[revision["id"]]
        selected_ids=set(selection)
        payload={"kind":kind,"context_ref":context["id"],"source_hash":context["source_hash"],"source_revision":context["id"],"cad_revision":revision["id"] if cad_used else None,
                 "analysis_policy_id":VERSION,"normalized_query":copy.deepcopy(query),"selection":{"source_members":members,"cad_members":cad_members,"construction_members":[]},
                 "source_selection":{"triangle_ids":sorted(selection)},"regions":regions,"measurements":_measure(analysis,selection),"cad_measurements":cad_measurements,"sections":sections,
                 "hit":hit,"stopped_barriers":stopped[:1000],"omitted_stopped_barrier_count":max(0,len(stopped)-1000),"interpretation_flags":["material_semantics_unresolved","observations_do_not_imply_a_bore_or_boss"],
                 "quality_flags":{"degenerate_triangle_ids":[tid for tid in analysis["degenerate_triangles"] if tid in selected_ids],
                                  "nonmanifold_edge_count":sum(len(uses)>2 and any(tid in selected_ids for tid,_ in uses) for uses in analysis["edges"].values()),
                                  "orientation_conflict_count":sum(len(uses)==2 and uses[0][1]==uses[1][1] and any(tid in selected_ids for tid,_ in uses) for uses in analysis["edges"].values())},
                 "completeness":{"complete":not omitted and not unknown_scope and not any(d["code"] in {"CAD_UNAVAILABLE","COMPARISON_UNAVAILABLE","COMPARISON_PARTIAL","BUDGET_EXHAUSTED"} for d in diagnostics),
                                 "processed_triangle_count":len(selection),"unprocessed_triangle_ids":sorted(set(omitted)|unknown_scope),"CAD_available":revision.get("_shape") is not None if cad_used else None},
                 "dependencies":dependencies,"units":context.get("units","mm"),"provenance":provenance}
        if isinstance(query.get("role"),str):payload["role"]=query["role"]
        payload["id"]="evidence-"+_hash(payload)[:24];payload["evidence_id"]=payload["id"]
        return {"status":"partial" if diagnostics or omitted else "ok","payload":payload,"diagnostics":diagnostics,"provenance":provenance}
    except (EvidenceError,ValueError,TypeError,KeyError,IndexError,RuntimeError) as error:
        return {"status":"error","payload":None,"diagnostics":[diagnostic(getattr(error,"code","INVALID_QUERY"),str(error),severity="error")],"provenance":provenance}
