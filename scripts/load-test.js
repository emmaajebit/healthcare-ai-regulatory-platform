// k6 load test for the java-healthcare-app demo service.
// Usage: k6 run scripts/load-test.js
// Override target with: TARGET_URL=http://localhost:8080 k6 run scripts/load-test.js
import http from 'k6/http';
import { check, sleep } from 'k6';

const TARGET_URL = __ENV.TARGET_URL || 'http://java-healthcare-app:8080';

export const options = {
  stages: [
    { duration: '10s', target: 10 },  // ramp up
    { duration: '20s', target: 30 },   // sustained load
    { duration: '10s', target: 0 },   // ramp down
  ],
  thresholds: {
    http_req_failed: ['rate<0.01'],      // < 1% failures
    http_req_duration: ['p(95)<500'],    // p95 < 500ms
    checks: ['rate>0.95'],                // > 95% of assertions pass
  },
};

export default function () {
  const res = http.get(`${TARGET_URL}/healthz`);
  check(res, {
    'status is 200': (r) => r.status === 200,
    'body has status ok': (r) => r.json('status') === 'ok',
  });
  sleep(0.2);
}
