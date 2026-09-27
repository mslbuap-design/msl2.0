/** @type {import('tailwindcss').Config} */
export default {
  content: ['./index.html', './src/**/*.{js,jsx}'],
  theme: {
    extend: {
      colors: {
        // Paleta "clínica": navy/gris frío como base, un solo acento teal.
        ink: '#14213D',
        muted: '#5B6B7A',
        faint: '#93A2AF',
        bg: '#F4F7F9',
        surface: '#FFFFFF',
        line: '#DCE3E8',
        accent: {
          DEFAULT: '#0F6E8C',
          50: '#EAF4F7',
          100: '#D2E7EC',
          600: '#0B5A73',
          700: '#094A5F',
        },
        success: {
          DEFAULT: '#1B7A43',
          50: '#E9F5EC',
        },
        danger: {
          DEFAULT: '#B3261E',
          50: '#FBEAE9',
        },
        warning: {
          DEFAULT: '#9A6A16',
          50: '#FBF3E3',
        },
      },
      fontFamily: {
        sans: ['"IBM Plex Sans"', 'ui-sans-serif', 'system-ui', 'sans-serif'],
        mono: ['"IBM Plex Mono"', 'ui-monospace', 'SFMono-Regular', 'Menlo', 'monospace'],
      },
      boxShadow: {
        panel: '0 1px 2px 0 rgba(20, 33, 61, 0.06)',
        overlay: '0 8px 24px -4px rgba(20, 33, 61, 0.25)',
      },
    },
  },
  plugins: [],
};
