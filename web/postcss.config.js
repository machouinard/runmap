// export default {
// 	plugins: {
// 		tailwindcss: {},
// 		autoprefixer: {},
// 	},
// }

import tailwindcss from 'tailwindcss'
import autoprefixer from 'autoprefixer'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)

export default {
	plugins: [
		// 👇 force Tailwind to use THIS app's config
		tailwindcss({
			config: path.resolve(__dirname, './tailwind.config.js'),
		}),
		autoprefixer(),
	],
}
