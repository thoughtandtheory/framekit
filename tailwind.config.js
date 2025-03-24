/** @type {import('tailwindcss').Config} */
module.exports = {
  content: [
    './views/**/*.erb',
    './public/**/*.{html,js}'
  ],
  theme: {
    extend: {
      animation: {
        'spin': 'spin 1s linear infinite'
      },
      keyframes: {
        spin: {
          '0%': { transform: 'rotate(0deg)' },
          '100%': { transform: 'rotate(360deg)' }
        }
      }
    },
  },
  plugins: [],
}
