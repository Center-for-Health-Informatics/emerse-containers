#!/usr/bin/env node
// Development stand-in for CHI Authentication's signer (Tools/auth lib/sso.js): a local
// P-256 key, its JWKS for the Valve to pin, and SSO-Assertion tokens on demand.
//
//   node dev/dev-signer.mjs jwks <config-dir>                 write <config-dir>/chi-auth-jwks.json
//   node dev/dev-signer.mjs token <username> [hours] [aud]    print a token (default 8 h)
//
// The key lives in dev/.dev-signing-key.pem (gitignored). Never point a real deployment
// at this JWKS: anyone with the key file can sign in as anyone.
import { createPrivateKey, createPublicKey, generateKeyPairSync, sign } from 'node:crypto'
import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const keyFile = join(here, '.dev-signing-key.pem')
const issuer = process.env.SSO_ISSUER ?? 'https://chi-tools.uc.edu/auth/'

function privateKey () {
  if (!existsSync(keyFile)) {
    const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' })
    writeFileSync(keyFile, privateKey.export({ type: 'pkcs8', format: 'pem' }), { mode: 0o600 })
  }
  return createPrivateKey(readFileSync(keyFile))
}

const b64 = (v) => Buffer.from(typeof v === 'string' ? v : JSON.stringify(v)).toString('base64url')
const kid = 'dev'

const [command, ...args] = process.argv.slice(2)
if (command === 'jwks' && args[0]) {
  const jwk = createPublicKey(privateKey()).export({ format: 'jwk' })
  writeFileSync(join(args[0], 'chi-auth-jwks.json'), JSON.stringify({ keys: [{ ...jwk, kid, alg: 'ES256', use: 'sig' }] }, null, 2) + '\n')
} else if (command === 'token' && args[0]) {
  const [sub, hours = '8', aud = process.env.SSO_AUDIENCE ?? 'chi-tools.uc.edu'] = args
  const now = Math.floor(Date.now() / 1000)
  const input = b64({ alg: 'ES256', kid, typ: 'JWT' }) + '.' +
    b64({ email: `${sub}@example.org`, given_name: 'Dev', family_name: sub, iss: issuer, aud, sub, iat: now, exp: now + Number(hours) * 3600 })
  const signature = sign('sha256', Buffer.from(input), { key: privateKey(), dsaEncoding: 'ieee-p1363' })
  process.stdout.write(`${input}.${signature.toString('base64url')}\n`)
} else {
  process.stderr.write(readFileSync(fileURLToPath(import.meta.url), 'utf8').split('\n').slice(1, 9).join('\n') + '\n')
  process.exit(2)
}
