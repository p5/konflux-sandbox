import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';

const [dir] = process.argv.slice(2);
const read = name => JSON.parse(fs.readFileSync(path.join(dir,name),'utf8'));
const stable = object => ({
  kind:object.kind,
  name:object.metadata.name,
  namespace:object.metadata.namespace,
  uid:object.metadata.uid,
  condition:object.status.conditions.filter(c=>c.type==='Succeeded').map(c=>({type:c.type,status:c.status,reason:c.reason})),
  results:object.status.results??[],
  steps:(object.status.steps??[]).map(s=>({name:s.name,terminated:s.terminated?{exitCode:s.terminated.exitCode,reason:s.terminated.reason}:null})),
});
assert.deepEqual(stable(read('archived-pipeline.json')),stable(read('live-pipeline.json')));
for(const task of read('live-taskruns.json').items){
  assert.deepEqual(stable(read(`archived-${task.metadata.name}.json`)),stable(read(`live-${task.metadata.name}.json`)));
}
const failed=read('live-taskruns.json').items.find(t=>t.metadata.labels['tekton.dev/pipelineTask']==='check');
assert(failed.status.steps.some(s=>s.terminated?.exitCode===23));
console.log('PASS Results PipelineRun and TaskRun identity, terminal state, structured results, and step exit codes match live Kubernetes objects');
