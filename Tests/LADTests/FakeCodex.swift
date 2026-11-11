import Foundation
import XCTest

/// A real JSON-RPC stdio app-server fixture. Legacy shell scenarios are kept
/// behind this adapter so reference/error/stream/cancellation coverage stays
/// independent of the public transport framing used by LAD.
struct FakeCodex {
    let directory: URL
    let executable: URL
    let inputURL: URL
    let argumentsURL: URL
    let captureURL: URL
    let workingDirectoryURL: URL
    let threadRequestURL: URL
    let turnRequestURL: URL
    let rpcRequestsURL: URL
    let steeringURL: URL

    init(body: String) throws {
        try self.init(body: body, responseJSON: nil, delay: 0, steeringMode: "ack")
    }

    init(responseJSON: String, delay: Double = 0.25, steeringMode: String = "ack") throws {
        try self.init(body: nil, responseJSON: responseJSON, delay: delay, steeringMode: steeringMode)
    }

    private init(body: String?, responseJSON: String?, delay: Double, steeringMode: String) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-FakeCodex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        executable = directory.appendingPathComponent("codex")
        inputURL = directory.appendingPathComponent("request.txt")
        argumentsURL = directory.appendingPathComponent("arguments.txt")
        captureURL = directory.appendingPathComponent("captured")
        workingDirectoryURL = directory.appendingPathComponent("working-directory.txt")
        threadRequestURL = directory.appendingPathComponent("thread-request.json")
        turnRequestURL = directory.appendingPathComponent("turn-request.json")
        rpcRequestsURL = directory.appendingPathComponent("rpc-requests.jsonl")
        steeringURL = directory.appendingPathComponent("steering.jsonl")
        var configuration: [String: Any] = [
            "inputPath": inputURL.path, "argumentsPath": argumentsURL.path, "capturePath": captureURL.path,
            "workingPath": workingDirectoryURL.path, "threadPath": threadRequestURL.path,
            "turnPath": turnRequestURL.path, "rpcPath": rpcRequestsURL.path, "steeringPath": steeringURL.path,
            "delay": delay, "steeringMode": steeringMode,
            "ignoreTerm": body?.contains("trap '' TERM") == true,
            "inheritOutput": body?.contains(" &") == true
        ]
        if let responseJSON { configuration["responseJSON"] = responseJSON }
        if let body {
            let bodyURL = directory.appendingPathComponent("scenario.sh")
            try ("#!/bin/sh\n" + body + "\n").write(to: bodyURL, atomically: true, encoding: .utf8)
            configuration["bodyPath"] = bodyURL.path
        }
        let encoded = try JSONSerialization.data(withJSONObject: configuration, options: [.sortedKeys]).base64EncodedString()
        let preamble = "#!/usr/bin/python3\nimport base64,json\nCONFIG=json.loads(base64.b64decode('\(encoded)'))\n"
        try (preamble + Self.adapter).write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    func arguments() throws -> [String] {
        try String(contentsOf: argumentsURL, encoding: .utf8).components(separatedBy: .newlines).filter { !$0.isEmpty }
    }

    func turnRequest() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: turnRequestURL)) as? [String: Any])
    }

    func threadRequest() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: threadRequestURL)) as? [String: Any])
    }

    func rpcRequests() throws -> [[String: Any]] {
        try String(contentsOf: rpcRequestsURL, encoding: .utf8).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    func capturedData(at stagedPath: String) throws -> Data {
        let workingPath = try String(contentsOf: workingDirectoryURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let components = URL(fileURLWithPath: stagedPath).pathComponents
        let contextIndex = try XCTUnwrap(components.firstIndex(where: { $0 == "context" || $0 == "sources" }), "Expected a staged context or source path: \(stagedPath)")
        let stagedJob = URL(fileURLWithPath: NSString.path(withComponents: Array(components[..<contextIndex])))
        let workingJob = URL(fileURLWithPath: workingPath)
        let canonicalStagedJob = stagedJob.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(stagedJob.lastPathComponent)
        let canonicalWorkingJob = workingJob.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(workingJob.lastPathComponent)
        XCTAssertEqual(canonicalStagedJob.path, canonicalWorkingJob.path, "The reference must point to the actual Codex task workspace")
        let captured = components[contextIndex...].reduce(captureURL) { $0.appendingPathComponent($1) }
        return try Data(contentsOf: captured)
    }

    func assertJobWasCleanedUp(file: StaticString = #filePath, line: UInt = #line) throws {
        let path = try String(contentsOf: workingDirectoryURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(path.contains("LAD-Codex-"), file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "Private staged files must be removed when the request finishes", file: file, line: line)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    private static let adapter = #"""
import os, pathlib, shutil, signal, stat, subprocess, sys, threading, time

pathlib.Path(CONFIG['argumentsPath']).write_text('\n'.join(sys.argv[1:])+'\n')
write_lock=threading.Lock()
finish_lock=threading.Lock()
finish_event=threading.Event()
finished=False
final_seen=False
error_text=''
child=None
thread_id='thread'
turn_id='turn'
split_emoji=True

if CONFIG['ignoreTerm']:
    signal.signal(signal.SIGTERM,signal.SIG_IGN)

def write_bytes(data):
    global split_emoji
    with write_lock:
        marker=data.find(b'\xf0') if split_emoji else -1
        if marker>=0:
            split_emoji=False
            sys.stdout.buffer.write(data[:marker+1]);sys.stdout.buffer.flush()
            time.sleep(0.02)
            sys.stdout.buffer.write(data[marker+1:]);sys.stdout.buffer.flush()
        else:
            sys.stdout.buffer.write(data);sys.stdout.buffer.flush()

def frame(value):
    write_bytes(json.dumps(value,ensure_ascii=False,separators=(',',':')).encode()+b'\n')

def reply(identity,value):
    frame({'id':identity,'result':value})

def notify(method,params):
    frame({'method':method,'params':params})

def item(value,completed=True):
    notify('item/completed' if completed else 'item/started',{'threadId':thread_id,'turnId':turn_id,'item':value})

def completion(status='completed',error=None):
    value={'id':turn_id,'status':status,'items':[],'error':error}
    notify('turn/completed',{'threadId':thread_id,'turn':value})

def public_line(raw):
    global final_seen,error_text
    try:value=json.loads(raw)
    except (ValueError,UnicodeError):
        write_bytes(raw if raw.endswith(b'\n') else raw+b'\n')
        return
    if not isinstance(value,dict):return
    if 'method' in value:
        frame(value);return
    kind=value.get('type')
    if kind in ('item.started','item.updated','item.completed'):
        source=dict(value.get('item',{}))
        source['type']={'agent_message':'agentMessage','command_execution':'commandExecution','file_change':'fileChange','mcp_tool_call':'mcpToolCall','web_search':'webSearch'}.get(source.get('type'),source.get('type'))
        for old,new in [('aggregated_output','aggregatedOutput'),('exit_code','exitCode'),('duration_ms','durationMs')]:
            if old in source:source[new]=source.pop(old)
        if source.get('type')=='agentMessage':
            if source.get('phase') is None and source.get('channel') is not None:source['phase']=source['channel']
            text=source.get('text','').strip()
            if kind=='item.completed' and (source.get('phase')=='final_answer' or (source.get('phase') is None and text.startswith('{'))):final_seen=True
        item(source,kind=='item.completed')
    elif kind in ('turn.failed','error'):
        error_text=value.get('error',{}).get('message') or value.get('message') or 'The task failed.'
        notify('error',{'threadId':thread_id,'turnId':turn_id,'error':{'message':error_text}})

def safe_final():
    output=pathlib.Path.cwd()/'model.json'
    try:
        info=output.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_nlink!=1 or not 0<info.st_size<=4_000_000:return None
        return output.read_text()
    except (OSError,UnicodeError):return None

def finish(status='completed',message=None):
    global finished,final_seen
    with finish_lock:
        if finished:return
        finished=True
        if status!='completed':
            completion(status,{'message':message or error_text or 'The task failed.'});return
        if not final_seen:
            text=CONFIG.get('responseJSON')
            if text is None:text=safe_final()
            if text is None:
                completion('failed',{'message':'Codex completed without a bounded structured CAD response.'});return
            item({'id':'final','type':'agentMessage','phase':'final_answer','text':text})
            final_seen=True
        completion()

def run_scenario():
    global child,error_text
    if 'responseJSON' in CONFIG:
        item({'id':'plan','type':'agentMessage','phase':'commentary','text':'The design request is running.'})
        finish_event.wait(CONFIG['delay'])
        finish();return
    env=dict(os.environ);env['output']=str(pathlib.Path.cwd()/'model.json')
    child=subprocess.Popen(['/bin/sh',CONFIG['bodyPath']],stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env,start_new_session=True)
    if CONFIG['inheritOutput']:
        subprocess.Popen(['/bin/sleep','3'],stdout=sys.stdout,stderr=sys.stderr)
    errors=[]
    def drain_errors():
        for chunk in iter(lambda:child.stderr.read(16384),b''):
            errors.append(chunk)
            sys.stderr.buffer.write(chunk);sys.stderr.buffer.flush()
    reader=threading.Thread(target=drain_errors,daemon=True);reader.start()
    for raw in iter(child.stdout.readline,b''):
        public_line(raw)
        if CONFIG['ignoreTerm']:
            # The app-server itself owns the unresponsive-process simulation;
            # do not leave an unrelated 30-second sleep behind after SIGKILL.
            try:os.killpg(child.pid,signal.SIGKILL)
            except ProcessLookupError:pass
            child.wait()
            return
    code=child.wait();reader.join(timeout=0.3)
    if code:
        diagnostic=b''.join(errors).decode(errors='replace').strip()
        finish('failed',error_text or diagnostic or f'Codex exited with status {code}.')
    else:finish()

def record(path,value,append=False):
    with open(path,'a' if append else 'w') as file:file.write(json.dumps(value,ensure_ascii=False)+'\n')

def capture_context():
    destination=pathlib.Path(CONFIG['capturePath']);destination.mkdir(exist_ok=True)
    for name in ('context','sources'):
        source=pathlib.Path.cwd()/name
        if source.is_dir():shutil.copytree(source,destination/name,dirs_exist_ok=True)

try:
    for raw in sys.stdin.buffer:
        request=json.loads(raw)
        record(CONFIG['rpcPath'],request,True)
        if 'id' not in request:continue
        identity=request['id'];method=request.get('method');params=request.get('params',{})
        if method=='initialize':reply(identity,{})
        elif method=='thread/start':
            record(CONFIG['threadPath'],params)
            reply(identity,{'thread':{'id':thread_id}})
        elif method=='turn/start':
            record(CONFIG['turnPath'],params)
            prompt='\n'.join(entry.get('text','') for entry in params.get('input',[]) if entry.get('type')=='text')
            pathlib.Path(CONFIG['inputPath']).write_text(prompt)
            pathlib.Path(CONFIG['workingPath']).write_text(os.getcwd()+'\n')
            capture_context()
            reply(identity,{'turn':{'id':turn_id,'status':'inProgress','items':[],'error':None}})
            threading.Thread(target=run_scenario,daemon=True).start()
        elif method=='turn/steer':
            record(CONFIG['steeringPath'],params,True)
            capture_context()
            mode=CONFIG['steeringMode']
            if mode=='reject':frame({'id':identity,'error':{'code':-32602,'message':'Steering rejected by fixture.'}})
            else:
                if mode=='finish-before-ack':
                    finish_event.set();finish();time.sleep(0.1)
                reply(identity,{'turnId':turn_id})
        elif method=='turn/interrupt':
            if not CONFIG['ignoreTerm']:
                reply(identity,{});finish('interrupted')
        else:frame({'id':identity,'error':{'code':-32601,'message':'Unknown mock method.'}})
    if CONFIG['ignoreTerm']:
        while True:time.sleep(1)
finally:
    if child is not None and child.poll() is None and not CONFIG['ignoreTerm']:
        try:os.killpg(child.pid,signal.SIGTERM)
        except ProcessLookupError:pass
"""#
}
