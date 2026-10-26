import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
const root=process.cwd();
const migration=fs.readFileSync(path.join(root,'supabase','migrations','20261026120000_monitoring_core.sql'),'utf8');
const backend=fs.readFileSync(path.join(root,'web','backend.js'),'utf8');
const app=fs.readFileSync(path.join(root,'web','app.js'),'utf8');

test('monitoring migration defines role-safe core model',()=>{
 assert.match(migration,/role in \('admin','inspector','monitoring'\)/);
 for(const table of ['monitoring_criteria','monitoring_issues','issue_actions','issue_change_requests','attachments','notifications','supervisor_leave_requests','weekly_compliance'])assert.match(migration,new RegExp('create table if not exists public\\.'+table));
 assert.match(migration,/penalty_applied/);
 assert.match(migration,/monitoring_issues_branch_created_idx/);
 assert.match(migration,/grant execute on function public\.monitoring_api/);
});
test('browser routes monitoring requests through dedicated RPC',()=>{
 assert.ok(backend.includes("route.startsWith('/monitoring')||route.startsWith('/notifications')"));
 assert.ok(backend.includes("client.rpc('monitoring_api'"));
});
test('UI exposes Georgian role labels and monitoring issue navigation',()=>{
 assert.match(app,/ვაიზერი/);
 assert.match(app,/მონიტორინგი/);
 assert.match(app,/monitoring-issues/);
});


