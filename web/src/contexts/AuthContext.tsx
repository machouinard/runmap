import React, { createContext, useContext, useState, useEffect } from 'react'

interface AuthContextType {
  isAdmin: boolean
  apiKey: string | null
  login: (key: string) => Promise<boolean>
  logout: () => void
  getAuthHeaders: () => HeadersInit
}

const AuthContext = createContext<AuthContextType | null>(null)

const STORAGE_KEY = 'runmap_admin_key'

export function AuthProvider({ children }: { children: React.ReactNode }) {
  const [apiKey, setApiKey] = useState<string | null>(null)

  // Load API key from localStorage on mount
  useEffect(() => {
    const storedKey = localStorage.getItem(STORAGE_KEY)
    if (storedKey) {
      setApiKey(storedKey)
    }
  }, [])

  const login = async (key: string): Promise<boolean> => {
    // Validate the key by testing against a protected endpoint
    try {
      const response = await fetch('/api/processing-queue/stats', {
        headers: {
          'X-API-Key': key
        }
      })

      if (response.ok) {
        // Valid key
        localStorage.setItem(STORAGE_KEY, key)
        setApiKey(key)
        return true
      } else {
        // Invalid key
        return false
      }
    } catch (error) {
      console.error('Login validation error:', error)
      return false
    }
  }

  const logout = () => {
    localStorage.removeItem(STORAGE_KEY)
    setApiKey(null)
  }

  const getAuthHeaders = (): HeadersInit => {
    if (apiKey) {
      return {
        'X-API-Key': apiKey,
        'Content-Type': 'application/json'
      }
    }
    return {
      'Content-Type': 'application/json'
    }
  }

  return (
    <AuthContext.Provider
      value={{
        isAdmin: !!apiKey,
        apiKey,
        login,
        logout,
        getAuthHeaders
      }}
    >
      {children}
    </AuthContext.Provider>
  )
}

export function useAuth() {
  const context = useContext(AuthContext)
  if (!context) {
    throw new Error('useAuth must be used within AuthProvider')
  }
  return context
}
