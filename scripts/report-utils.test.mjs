import test from 'node:test';
import assert from 'node:assert/strict';
import {sortBranches,formatDuration} from '../web/report-utils.js';
test('branch ranking supports score, name, inspection count and issue count without changing input',()=>{
 const rows=[{branch_name:'B',score:2,inspections:7,issues:4},{branch_name:'A',score:5,inspections:2,issues:0}];
 for(const [sort,first] of [['score-desc','A'],['score-asc','B'],['name','A'],['count','B'],['issues','B']])assert.equal(sortBranches(rows,sort)[0].branch_name,first);
 assert.equal(rows[0].branch_name,'B');
});
test('duration preserves unknown historical times and minute/hour boundaries',()=>{
 assert.equal(formatDuration(null),'—');assert.equal(formatDuration(0),'0 სთ 0 წთ 0 წმ');assert.equal(formatDuration(3661),'1 სთ 1 წთ 1 წმ');
});
