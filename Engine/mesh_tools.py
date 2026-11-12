"""File boundary for task-scoped iterative reconstruction.

Trusted handles and branch transactions live in the native task session. Every
worker receives immutable copies, executes in the ordinary CAD sandbox, and
returns new records. Intermediate validity is independent of final agreement.
"""
from __future__ import annotations

import ast
import copy
from fractions import Fraction
import hashlib
import json
import math
from pathlib import Path
import re
import stat
import struct
import uuid

from mesh_reference import canonical, canonical_digest, geometry_digest

VERSION = "iterative-mesh-1"
MAX_FILE = 512_000_000  # Match the app's geometry-file admission limit.
MAX_SOURCE_TRIANGLES = 1_000_000
# Reference coordinates travel once, as binary arrays beside the context; the
# context JSON keeps only metadata and the geometry's identity.
REFERENCE_ASSET = "mesh-reference.npz"
REFERENCE_ARRAYS = ("vertices", "triangles", "original_vertices")
UNIT_RATIOS = {"mm":(1,1), "cm":(10,1), "m":(1000,1), "um":(1,1000),
               "µm":(1,1000), "in":(127,5), "inch":(127,5), "ft":(1524,5)}


def identity(prefix, value):
    return prefix + "-" + canonical_digest(value)


def read_asset(directory, name, maximum=MAX_FILE):
    if not isinstance(name,str) or not name or Path(name).name != name:
        raise ValueError("A private worker asset name is required")
    path=Path(directory)/name
    info=path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or not 0 < info.st_size <= maximum:
        raise ValueError("Worker assets must be bounded regular private files")
    return path


def read_json(directory,name,maximum=MAX_FILE):
    return json.loads(read_asset(directory,name,maximum).read_text())


def diagnostic(code,message,**details):
    return {"code":code,"severity":"error","message":message,
            "related_entity_refs":[],"evidence_refs":[],"recoverable":True,
            "suggested_actions":[],**details}


def envelope(context,payload,status="ok",diagnostics=(),dependencies=()):
    return {"status":status,"payload":payload,"diagnostics":list(diagnostics),
            "provenance":{"context_ref":context.get("id"),"source_hash":context.get("source_hash"),
                          "dependency_revisions":list(dependencies),"parameters":{},
                          "algorithm_versions":{"toolbox":VERSION},
                          "numerical_policy":"represented binary64; estimates and conservative bounds distinguished",
                          "seed":context.get("seed",0)}}


def _mesh(path,data):
    import numpy as np
    if path.suffix.lower()==".json":
        data=json.loads(data.decode("utf-8"))
        if not isinstance(data,dict) or set(data)!={"vertices","triangles"}:
            raise ValueError("Mesh JSON requires vertices and zero-based triangles")
        vertices=np.asarray(data["vertices"],dtype=float)
        raw=np.asarray(data["triangles"])
        if raw.dtype.kind not in "iu":raise ValueError("Triangle indices must be integers")
        triangles=raw.astype(np.int64)
    elif path.suffix.lower()==".stl":
        count=struct.unpack_from("<I",data,80)[0] if len(data)>=84 else 0
        if count and 84+50*count==len(data):
            if count>MAX_SOURCE_TRIANGLES:raise ValueError("Source triangle budget exceeded")
            facets=np.frombuffer(data,dtype=np.dtype([("normal","<f4",3),("corners","<f4",(3,3)),("attribute","<u2")]),
                                 count=count,offset=84)
            vertices=facets["corners"].reshape(-1,3).astype(float)
        else:
            text=data.decode("utf-8")
            values=re.findall(r"(?im)^\s*vertex\s+(\S+)\s+(\S+)\s+(\S+)\s*$",text)
            if len(values)>3*MAX_SOURCE_TRIANGLES or len(values)%3:
                raise ValueError("Invalid or over-budget STL triangles")
            vertices=np.asarray(values,dtype=float)
        triangles=np.arange(len(vertices),dtype=np.int64).reshape(-1,3)
    else:raise ValueError("Open an STL or indexed triangle JSON reference")
    if vertices.ndim!=2 or vertices.shape[1]!=3 or not 0<len(vertices)<=3*MAX_SOURCE_TRIANGLES or not np.isfinite(vertices).all():
        raise ValueError("Source vertices must be finite three-dimensional coordinates")
    if triangles.ndim!=2 or triangles.shape[1]!=3 or not 0<len(triangles)<=MAX_SOURCE_TRIANGLES or triangles.min()<0 or triangles.max()>=len(vertices):
        raise ValueError("Invalid source triangle indices or triangle budget")
    return vertices,triangles


def open_reference(path,*,units,max_deviation,source_kind="unknown",policy=None):
    import numpy as np
    if units not in UNIT_RATIOS:raise ValueError("Declare supported source units: mm, cm, m, um, in or ft")
    if isinstance(max_deviation,bool) or not isinstance(max_deviation,(int,float)) or not math.isfinite(max_deviation) or max_deviation<0:
        raise ValueError("Maximum deviation must be finite and nonnegative")
    if source_kind not in {"unknown","cad_tessellation","scan"}:raise ValueError("Invalid source kind")
    policy=copy.deepcopy(policy or {})
    if not isinstance(policy,dict):raise ValueError("Reference policy must be an object")
    allowed={"reference_interpretation","completion_obligations","active_invariants","requirement_definitions","fit_policy","query_policy","compare_policy","seed"}
    if set(policy)-allowed:raise ValueError("Unknown reference policy fields")
    for key in ("completion_obligations","active_invariants"):
        if not isinstance(policy.get(key,[]),list) or len(policy.get(key,[]))>256:raise ValueError("Requirement lists exceed their budget")
    for key in ("reference_interpretation","fit_policy","query_policy","compare_policy"):
        if not isinstance(policy.get(key,{}),dict):raise ValueError("Policy fields must be JSON objects")
    if type(policy.get("seed",0)) is not int or not 0<=policy.get("seed",0)<=2**32-1:raise ValueError("Invalid deterministic seed")
    data=path.read_bytes()
    vertices,triangles=_mesh(path,data)
    n,d=UNIT_RATIOS[units];factor=n/d
    normalized=vertices*factor
    if not np.isfinite(normalized).all() or np.max(np.abs(normalized))>1_000_000:
        raise ValueError("Reference exceeds the working coordinate limit")
    # Bound conversion of the original represented coordinates to working mm.
    # The final oracle adds this margin; the rounded analysis mesh is never
    # silently substituted for the exact physical unit transform.
    conversion_error=0.
    if (n,d)!=(1,1):
        factor_error=math.nextafter(float(abs(Fraction.from_float(factor)-Fraction(n,d))),math.inf)
        coordinate_errors=[]
        for axis in range(3):
            magnitude=float(np.max(np.abs(vertices[:,axis])))
            physical=float(np.max(np.abs(normalized[:,axis])))
            product_error=math.nextafter(magnitude*factor_error,math.inf)
            coordinate_errors.append(math.nextafter(product_error+math.ulp(physical),math.inf))
        squared=0.
        for error in coordinate_errors:squared=math.nextafter(squared+math.nextafter(error*error,math.inf),math.inf)
        conversion_error=math.nextafter(math.sqrt(squared),math.inf)
    exact_allowance=Fraction.from_float(float(max_deviation))*Fraction(n,d)
    allowance=float(exact_allowance)
    if not math.isfinite(allowance):raise ValueError("Deviation exceeds the working range")
    if Fraction.from_float(allowance)>exact_allowance:allowance=math.nextafter(allowance,-math.inf)
    source_hash=hashlib.sha256(data).hexdigest()
    context={"source_hash":source_hash,"units":"mm","source_units":units,
             "max_deviation":allowance,"source_max_deviation":float(max_deviation),
             "source_kind":source_kind,
             "geometry":{"vertex_count":len(normalized),"triangle_count":len(triangles),
                         "digest":geometry_digest(normalized,triangles),"original_vertices":(n,d)!=(1,1)},
             "source_transform":{"scale_ratio":[n,d],"working_frame":"original axes and origin in millimeters"},
             "conversion_arithmetic_margin":conversion_error,"policy":policy,"seed":policy.get("seed",0),
             "bounds":{"min":normalized.min(axis=0).tolist(),"max":normalized.max(axis=0).tolist(),
                       "diagonal":float(np.linalg.norm(normalized.max(axis=0)-normalized.min(axis=0)))},
             "algorithm_version":VERSION,"completion_obligations":policy.get("completion_obligations",[]),
             "active_invariants":policy.get("active_invariants",[])}
    for key in ("fit_policy","query_policy","compare_policy"):context[key]=policy.get(key,{})
    context["id"]=identity("context",context)
    # The returned context carries the arrays in memory; publishing moves them
    # into the binary reference asset.
    context["vertices"]=normalized;context["triangles"]=triangles
    if (n,d)!=(1,1):context["original_vertices"]=vertices
    revision={"id":identity("revision",{"context":context["id"],"empty":True}),"context_ref":context["id"],
              "source_hash":source_hash,"script":None,"body_ids":[],"constructions":{},"parameter_bindings":{},
              "constraints":[],"active_invariants":copy.deepcopy(context["active_invariants"]),
              "completion_obligations":copy.deepcopy(context["completion_obligations"]),
              "geometry_hash":None,"dependencies":[],"representation":{"status":"empty"}}
    return context,revision


def write_reference(context,output):
    """Move a context's arrays into the binary reference asset; return metadata."""
    import numpy as np
    arrays={"vertices":np.ascontiguousarray(context["vertices"],dtype=np.float64),
            "triangles":np.ascontiguousarray(context["triangles"],dtype=np.int32)}
    if "original_vertices" in context:arrays["original_vertices"]=np.ascontiguousarray(context["original_vertices"],dtype=np.float64)
    with (Path(output)/REFERENCE_ASSET).open("wb") as stream:np.savez(stream,**arrays)
    return {key:value for key,value in context.items() if key not in REFERENCE_ARRAYS}


def attach_reference(context,directory,name):
    """Load the staged binary reference into an in-memory context."""
    import numpy as np
    geometry=context.get("geometry")
    if not isinstance(geometry,dict):raise ValueError("The reference context has no geometry record")
    with np.load(read_asset(directory,name),allow_pickle=False) as arrays:
        names=set(arrays.files)
        expected={"vertices","triangles"}|({"original_vertices"} if geometry.get("original_vertices") else set())
        if names!=expected:raise ValueError("The reference geometry file is invalid")
        vertices=np.asarray(arrays["vertices"],dtype=np.float64)
        triangles=np.asarray(arrays["triangles"])
        original=np.asarray(arrays["original_vertices"],dtype=np.float64) if "original_vertices" in names else None
    if triangles.dtype.kind not in "iu":raise ValueError("The reference triangle indices are invalid")
    triangles=triangles.astype(np.int64)
    if (geometry.get("vertex_count")!=len(vertices) or geometry.get("triangle_count")!=len(triangles)
            or geometry.get("digest")!=geometry_digest(vertices,triangles)):
        raise ValueError("The reference geometry does not match its context")
    context.update(vertices=vertices,triangles=triangles)
    if original is not None:context["original_vertices"]=original
    return context


def _base_comparison(directory,spec,context,revision):
    """A stored preview comparison of the unchanged base revision, if supplied.

    Comparisons sample deterministically, so a matching report equals a fresh
    one and later edits of the same revision need not recompute it. The
    trusted session re-encodes records, so identity fields, not a hash of the
    report, establish the match.
    """
    if not spec.get("baseComparisonAsset"):return None
    base=read_json(directory,spec["baseComparisonAsset"])
    if (base.get("model_ref")!=revision["id"] or base.get("context_revision")!=context["id"]
            or base.get("source_hash")!=context["source_hash"] or base.get("geometry_hash")!=revision.get("geometry_hash")
            or base.get("quality_requested")!="preview" or base.get("scope_requested")!="all"
            or not isinstance(base.get("comparison_id"),str)):
        return None
    return base


def _target(context,revision,directory,spec):
    import cadquery as cq
    target=copy.deepcopy(revision)
    target["shape"]=None
    if spec.get("brepAsset"):
        path=read_asset(directory,spec["brepAsset"])
        if hashlib.sha256(path.read_bytes()).hexdigest()!=revision.get("geometry_hash"):
            raise ValueError("Native geometry does not match the immutable revision")
        target["shape"]=cq.Shape.importBrep(str(path))
    elif revision.get("body_ids"):
        raise ValueError("Native geometry is unavailable for this revision")
    target["state"]={key:copy.deepcopy(revision.get(key)) for key in ("body_ids","constraints","active_invariants","completion_obligations","constructions")}
    return target


def _self_contained(script):
    tree=ast.parse(script)
    forbidden={"imported_assets","imported_model","open","importBrep","importStep","importShape","Read_s","Read","read","read_text","read_bytes"}
    for node in ast.walk(tree):
        if isinstance(node,ast.Name) and node.id in forbidden or isinstance(node,ast.Attribute) and node.attr in forbidden|{"importers"}:
            raise ValueError("Reconstruction programs must construct geometry directly and replay without generated geometry or external files")


def _dependencies(record,context,revision):
    if record.get("context_ref",context["id"])!=context["id"] or record.get("source_hash",context["source_hash"])!=context["source_hash"]:
        raise ValueError("Source-dependent record belongs to another context")
    def validate(value):
        if isinstance(value,list):
            for item in value:validate(item)
        elif isinstance(value,dict):
            for key,item in value.items():
                if key in {"revision_id","cad_revision","based_on_revision"} and item and item!=revision["id"]:
                    raise ValueError("STALE_DEPENDENCY: CAD-dependent evidence belongs to another revision")
                if key=="source_hash" and item!=context["source_hash"]:raise ValueError("Source dependency changed")
                if key in {"context_ref","context_revision"} and item and item!=context["id"]:raise ValueError("Context dependency changed")
                if key=="geometry_hash" and item and item!=revision.get("geometry_hash"):raise ValueError("Native geometry dependency changed")
                validate(item)
    validate(record.get("dependencies",{}))
    validate({"based_on_revision":record.get("based_on_revision"),"cad_revision":record.get("cad_revision")})


def _has_program_replacement(edit):
    return edit.get("operation")=="program_replace" or any(_has_program_replacement(item) for item in edit.get("edits",[]) if isinstance(item,dict))


def _compact(value,depth=0):
    large={"vertices","original_vertices","triangles","triangle_ids","source_members","samples","source_samples","residuals","points","segments","loops",
           "recognition_unknown_triangle_ids","supporting_triangle_ids"}
    if isinstance(value,dict):
        return {key:({"count":len(item),"available_in":"recordPath"} if key in large and isinstance(item,(list,dict)) else _compact(item,depth+1))
                for key,item in value.items() if key not in {"script","program","_shape","shape"}}
    if isinstance(value,list):
        result=[_compact(item,depth+1) for item in value[:24]]
        if len(value)>24:result.append({"omitted_count":len(value)-24,"available_in":"recordPath"})
        return result
    return value


def execute(spec,directory,output,threads=1,*,worker):
    """Create immutable worker records; never advance the native branch tip.

    `worker` is the running worker module, which supplies the CAD build,
    validation and preview pipeline. Never import it here: run as a script it
    is __main__, and importing worker would load a second copy of its state.
    """
    from mesh_inspect import inspect
    from mesh_fit import fit
    from mesh_compare import compare,check_requirements,audit_body
    from mesh_edits import compile_edit
    operation=spec.get("operation")
    options=spec.get("options",{})
    if not isinstance(options,dict):raise ValueError("Tool options must be an object")
    output=Path(output);output.mkdir(parents=True,exist_ok=True)
    context={};native_preview=False;script=None
    if operation=="mesh_open_reference":
        policy=read_json(directory,spec["policyAsset"]) if spec.get("policyAsset") else None
        context,revision=open_reference(read_asset(directory,spec["sourceAsset"]),policy=policy,**options)
        context=write_reference(context,output)
        result=envelope(context,{"context":context,"revision":revision})
    else:
        context=attach_reference(read_json(directory,spec["contextAsset"]),directory,spec.get("referenceAsset"))
        revision=read_json(directory,spec["revisionAsset"]) if spec.get("revisionAsset") else {}
        if revision and (revision.get("context_ref")!=context["id"] or revision.get("source_hash")!=context["source_hash"]):
            raise ValueError("Revision belongs to another reference context")
        target=_target(context,revision,directory,spec) if revision else None
        if operation=="mesh_inspect":
            evidence=read_json(directory,spec["evidenceAsset"]) if spec.get("evidenceAsset") else []
            records={item.get("id",item.get("evidence_id")):item for item in evidence}
            query=read_json(directory,spec["queryAsset"],2_000_000)
            if query.get("kind")=="discrepancies" and query.get("freshness","refresh_or_partial")!="no_refresh":
                target["comparison"]=compare(context,target,scope=query.get("scope","all"),quality="preview")
            inspected={**revision,"_shape":target["shape"],"comparison":target.get("comparison")}
            result=inspect(context,inspected,query,resolve_evidence=lambda ref:records[ref])
        elif operation=="mesh_fit":
            evidence=read_json(directory,spec["evidenceAsset"])
            for record in evidence:_dependencies(record,context,revision)
            constraints=read_json(directory,spec["constraintsAsset"]) if spec.get("constraintsAsset") else []
            result=fit(context,evidence,constraints=constraints,**options)
        elif operation=="mesh_compare":
            result=envelope(context,compare(context,target,**options),dependencies=[revision["id"]])
        elif operation=="mesh_try_edit":
            edit=read_json(directory,spec["editAsset"],2_000_000)
            if spec.get("programAsset"):edit["program"]=read_asset(directory,spec["programAsset"],worker.MAX_SCRIPT_BYTES).read_text()
            fits=read_json(directory,spec["fitsAsset"]) if spec.get("fitsAsset") else []
            def resolve_fit(ref,*_args):
                record=next(item for item in fits if item["id"]==ref)
                _dependencies(record,context,revision)
                return record
            plan=compile_edit(context,revision,edit,resolve_fit=resolve_fit)
            script=plan.get("script")
            preview={**plan,"base_revision":revision["id"],"context_ref":context["id"],"source_hash":context["source_hash"],
                     "id":"preview-"+uuid.uuid4().hex,
                     "state":"ready","commit_eligible":False,"validity_checks":{},"tolerance_changes":[],
                     "geometry_hash":revision.get("geometry_hash"),"representation":{"status":"reconstructed_brep",
                     "method":"authored_program" if _has_program_replacement(edit) or revision.get("representation",{}).get("method")=="authored_program" else "typed_cad_construction","source_hash":context["source_hash"]}}
            preview.pop("program",None)
            if script:_self_contained(script)
            try:
                shape=target["shape"]
                stats={}
                if plan.get("requires_body_validation"):
                    definition={"title":"Reconstruction preview","summary":"Staged iterative CAD edit.","units":"mm","script":script}
                    shape=worker.build_shape(definition,threads,Path(directory),preview_stats=stats)
                    import tempfile
                    import cadquery as cq
                    with tempfile.TemporaryDirectory(prefix=".mesh-step-",dir=output) as folder:
                        step=Path(folder)/"validation.step"
                        worker.write_step(stats["solids"],step,cq)
                        worker.validate_step_roundtrip(shape,cq,step,preview_stats=stats)
                    preview["validity_checks"]={"status":"valid","native_exact":True,"closed_positive_solids":True,"step_roundtrip":True}
                    preview["body_audit"]=audit_body(shape,face_budget=context.get("compare_policy",{}).get("native_si_face_budget",2048))
                elif shape is None:preview["validity_checks"]={"status":"not_evaluated","reason":"construction-only revision has no body"}
                else:preview["validity_checks"]=revision.get("validity_checks",{"status":"valid"})
                staged={**preview,"shape":shape,"id":"staged","state":plan.get("state",{})}
                requirements=check_requirements(context,staged,preview.get("active_invariants",[]))
                preview["active_invariant_checks"]=requirements
                preview["constraint_checks"]=check_requirements(context,staged,preview.get("constraints",[]))
                preview["completion_progress"]=check_requirements(context,staged,preview.get("completion_obligations",[]))
                preview["commit_eligible"]=(all(item.get("status")=="pass" for item in requirements+preview["constraint_checks"])
                                            and preview.get("body_audit",{}).get("status","pass")=="pass")
                if shape is not None and plan.get("requires_body_validation"):
                    display=worker.make_preview(shape,preview_stats=stats)
                    worker.write_brep(shape,output/"model.brep")
                    preview["geometry_hash"]=hashlib.sha256((output/"model.brep").read_bytes()).hexdigest()
                    display.update(stepPath=str((output/"model.step").resolve()),brepPath=str((output/"model.brep").resolve()),runtime=worker.runtime_info(cq),threads=threads,buildSeconds=0)
                    worker.write_preview_result(display,output);native_preview=True
                staged={**preview,"shape":shape,"state":plan.get("state",{})}
                # The base revision's report is stored once by the session and
                # referenced by ID; edits of the same revision reuse it.
                before=_base_comparison(directory,spec,context,revision)
                reused=before is not None
                if not reused:before=compare(context,target,quality="preview");preview["base_comparison"]=before
                preview["quick_comparison"]={"before_comparison_id":before["comparison_id"],"after":compare(context,staged,quality="preview"),
                                              "paired_source_sampling":True,"cache_reuse":"base comparison reused" if reused else "base comparison computed"}
                preview["representation_checks"]=preview["quick_comparison"]["after"]["representation_checks"]
                if shape is not None:
                    preview["commit_eligible"] &= all(check.get("status")=="pass" for check in preview["representation_checks"])
                if not preview["commit_eligible"]:preview["state"]="incomplete"
                result=envelope(context,preview,"ok" if preview["commit_eligible"] else "partial",dependencies=[revision["id"]])
            except (ValueError,RuntimeError) as error:
                preview.update(state="failed",commit_eligible=False,script=None)
                result=envelope(context,preview,"partial",[diagnostic("INVALID_BODY",str(error))],[revision["id"]])
                script=None
        elif operation=="mesh_export_step":
            comparison=read_json(directory,spec["comparisonAsset"])
            if comparison.get("acceptance")!="pass" or comparison.get("geometry_hash")!=revision.get("geometry_hash") or comparison.get("source_hash")!=context["source_hash"]:
                raise ValueError("Export requires a full accepted comparison for this exact revision")
            import cadquery as cq
            shape=target["shape"];worker.validate_shape(shape)
            colors=worker.export_solid_colors(read_json(directory,spec["colorsAsset"]) if spec.get("colorsAsset") else [],len(shape.Solids()))
            worker.write_step(shape.Solids(),output/"export.step",cq,colors=colors)
            worker.validate_step_roundtrip(shape,cq,output/"export.step")
            restored=cq.importers.importStep(str(output/"export.step")).val()
            readback={**target,"shape":restored,"id":revision["id"]+"/step-readback","geometry_hash":None}
            verified=compare(context,readback,quality="final")
            accepted=verified.get("acceptance")=="pass"
            result=envelope(context,{"exported":accepted,"revision_id":revision["id"],"source_geometry_hash":revision["geometry_hash"],
                                    "readback_comparison":verified,"step_sha256":hashlib.sha256((output/"export.step").read_bytes()).hexdigest() if accepted else None},
                            "ok" if accepted else "partial")
            if not accepted:(output/"export.step").unlink()
        else:raise ValueError("Unknown iterative mesh operation")
    (output/"mesh-record.json").write_bytes(canonical(result))
    if script and native_preview:(output/"mesh-program.py").write_text(script)
    metadata=_compact(result)
    metadata.update(native_preview=native_preview,program_available=bool(script and native_preview),step_available=(output/"export.step").exists())
    (output/"mesh-result.json").write_bytes(canonical(metadata))
    return metadata
