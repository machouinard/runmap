/** @type {import('tailwindcss').Config} */

const config = {
	content: ['./index.html', './src/**/*.{js,ts,jsx,tsx}'],
	theme: {
		extend: {
			colors: {
				incomplete: '#ff9900',
				complete: '#059669',
				runs: '#2256a3',
			},
		},
	},
	plugins: [],
}

console.log('Tailwind config:', new URL(import.meta.url).pathname)
console.log('runs color =', config.theme?.extend?.colors?.runs)

export default config
