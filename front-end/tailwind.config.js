/** @type {import('tailwindcss').Config} */
module.exports = {
  content: [
    "./src/**/*.{js,jsx,ts,tsx}",
  ],
  theme: {
    extend: {
      colors: {
        semanticBlue: '#007AFF', // Adding the custom color
      },
      boxShadow: {
        'outside-custom': '-4px -6px 8px rgba(0, 128, 0, 0.25)', // soft outer shadow
        
      },
      backgroundImage: {
        'gradient-emotion': 'linear-gradient(90deg, #339F43 39.97%, rgba(51, 159, 67, 0.50) 71.24%)',
      },
      fontFamily: {
        'alexandria': ['Alexandria', 'sans-serif'],
        'inter':['Inter' , 'sans-serif']
      }
    },
    
  },
  plugins: [],
}