// Check the two maintained catalogs and the strings supplied by other locales.
const fs = require('fs')
const path = require('path')
const dir = __dirname
const english = JSON.parse(fs.readFileSync(path.join(dir, 'en.json'), 'utf8'))
const placeholders = value => (String(value).match(/%\d+/g) || []).sort().join(',')
let errors = 0

function report(file, message) {
  console.error(`${file}: ${message}`)
  errors++
}

for (const file of fs.readdirSync(dir).filter(name => name.endsWith('.json'))) {
  const catalog = JSON.parse(fs.readFileSync(path.join(dir, file), 'utf8'))
  const maintained = file === 'en.json' || file === 'ru.json'
  for (const [key, source] of Object.entries(english)) {
    const translation = catalog[key]
    if (translation === undefined) {
      if (maintained) report(file, `missing ${key}`)
      continue
    }
    if (typeof source === 'string') {
      if (typeof translation !== 'string' || !translation.trim())
        report(file, `missing text for ${key}`)
      else if (placeholders(translation) !== placeholders(source))
        report(file, `placeholder mismatch in ${key}`)
      continue
    }
    const forms = file === 'ru.json' ? ['one', 'few', 'many', 'other']
      : file === 'en.json' ? ['one', 'other'] : ['other']
    if (!translation || typeof translation !== 'object' || Array.isArray(translation)
        || forms.some(form => typeof translation[form] !== 'string' || !translation[form].trim())) {
      report(file, `missing plural forms for ${key}`)
      continue
    }
    if (Object.values(translation).some(value => typeof value !== 'string'
        || placeholders(value) !== placeholders(source.other)))
      report(file, `placeholder mismatch in ${key}`)
  }
  if (maintained)
    for (const key of Object.keys(catalog))
      if (!(key in english)) report(file, `unexpected ${key}`)
}
if (errors) process.exitCode = 1
else console.log('English and Russian catalogs match. Available translations preserve placeholders.')
