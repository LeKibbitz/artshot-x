import test from 'node:test';
import assert from 'node:assert/strict';
import { normalizeRect, normalizeCuts, clampRect } from '../src/geometry.ts';
test('reverse drag gives positive rectangle', () => assert.deepEqual(normalizeRect({x:100,y:80},{x:20,y:30}),{x:20,y:30,width:80,height:50}));
test('selection cannot move outside display', () => assert.deepEqual(clampRect({x:950,y:-10,width:200,height:100},1000,700),{x:800,y:0,width:200,height:100}));
test('oversized selection shrinks to display', () => assert.deepEqual(clampRect({x:-100,y:0,width:1500,height:900},1000,700),{x:0,y:0,width:1000,height:700}));
test('internal removals merge overlaps and clamp duration without mutating input', () => {const source=[{start:8,end:15},{start:-2,end:3},{start:2,end:4},{start:5,end:5}];assert.deepEqual(normalizeCuts(source,10),[{start:0,end:4},{start:8,end:10}]);assert.equal(source[0].end,15)});
